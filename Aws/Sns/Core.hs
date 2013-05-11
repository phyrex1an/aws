module Aws.Sns.Core where

import Aws.Core
import           Aws.S3.Core                    (LocationConstraint, locationUsClassic, locationUsWest, locationUsWest2, locationApSouthEast, locationApNorthEast, locationEu)
import qualified Blaze.ByteString.Builder       as Blaze
import qualified Blaze.ByteString.Builder.Char8 as Blaze8
import qualified Control.Exception              as C
import qualified Control.Failure                as F
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Attempt                   (Attempt(..))
import qualified Data.ByteString                as B
import qualified Data.ByteString.Char8          as BC
import           Data.Conduit                   (($$+-))
import qualified Data.Conduit                   as C
import           Data.IORef
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Ord
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import qualified Data.Text.Encoding             as TE
import           Data.Time
import           Data.Typeable
import qualified Network.HTTP.Conduit           as HTTP
import qualified Network.HTTP.Types             as HTTP
import           System.Locale
import qualified Text.XML                       as XML
import           Text.XML.Cursor                (($/))
import qualified Text.XML.Cursor                as Cu

type ErrorCode = T.Text

data SnsError
    = SnsError {
        snsStatusCode :: HTTP.Status
      , snsErrorCode :: ErrorCode
      , snsErrorType :: T.Text      
      , snsErrorMessage :: T.Text
      , snsErrorDetail :: Maybe T.Text
      , snsErrorMetadata :: Maybe SnsMetadata
      }
    | SnsXmlError {
        snsXmlErrorMessage :: T.Text
      , snsXmlErrorMetadata :: Maybe SnsMetadata
      }
    deriving (Show, Typeable)

instance C.Exception SnsError

data SnsMetadata
    = SnsMetadata {
        snsMRequestId :: Maybe T.Text
      }
    deriving (Show)

instance Loggable SnsMetadata where
    toLogText (SnsMetadata {..}) = "SNS: request ID=" `mappend` 
                                   fromMaybe "<none>" snsMRequestId

instance Monoid SnsMetadata where
    mempty = SnsMetadata {
               snsMRequestId = Nothing
             }
    SnsMetadata {snsMRequestId = id1} `mappend` SnsMetadata{ snsMRequestId = id2 }
                    = SnsMetadata { snsMRequestId = id1 `mplus` id2 }

data Endpoint
    = Endpoint {
        endpointHost :: B.ByteString
      }
    deriving (Show)

data SnsConfiguration qt
    = SnsConfiguration {
        snsProtocol :: Protocol
      , snsEndpoint :: Endpoint
      , snsPort :: Int
      , snsUseUri :: Bool
      , snsDefaultExpiry :: NominalDiffTime
      }
    deriving (Show)

instance DefaultServiceConfiguration (SnsConfiguration NormalQuery) where
    defServiceConfig = sns HTTPS snsEndpointUsEast1 False
    debugServiceConfig = sns HTTP snsEndpointUsEast1 False

instance DefaultServiceConfiguration (SnsConfiguration UriOnlyQuery) where
    defServiceConfig = sns HTTPS snsEndpointUsEast1 True
    debugServiceConfig = sns HTTP snsEndpointUsEast1 True

snsEndpointUsEast1 = Endpoint { endpointHost = "sns.us-east-1.amazonaws.com" }
snsEndpointUsWest2 = Endpoint { endpointHost = "sns.us-west-2.amazonaws.com" }
snsEndpointUsWest1 = Endpoint { endpointHost = "sns.us-west-1.amazonaws.com" }
snsEndpointEuWest1 = Endpoint { endpointHost = "sns.eu-west-1.amazonaws.com" }
snsEndpointApSoutEast1 = Endpoint { endpointHost = "sns.ap-southeast-1.amazonaws.com" }
snsEndpointApSouthEast2 = Endpoint { endpointHost = "sns.ap-southeast-2.amazonaws.com" }
snsEndpointApNorthEast1 = Endpoint { endpointHost = "sns.ap-northeast-1.amazonaws.com" }
snsEndpointSaEast1 = Endpoint { endpointHost = "sns.sa-east-1.amazonaws.com" }

sns :: Protocol -> Endpoint -> Bool -> SnsConfiguration qt
sns protocol endpoint uri 
    = SnsConfiguration { 
        snsProtocol = protocol
      , snsEndpoint = endpoint
      , snsPort = defaultPort protocol
      , snsUseUri = uri
      , snsDefaultExpiry = 15*60
      }


data SnsQuery = SnsQuery {
      snsTopicArn :: Maybe TopicArn
    , snsQuery :: HTTP.Query
}

snsSignQuery :: SnsQuery -> SnsConfiguration qt -> SignatureData -> SignedQuery
snsSignQuery SnsQuery{..} SnsConfiguration{..} SignatureData{..}
    = SignedQuery {
        sqMethod = method
      , sqProtocol = snsProtocol
      , sqHost = endpointHost snsEndpoint
      , sqPort = snsPort
      , sqPath = path
      , sqQuery = signedQuery
      , sqDate = Just signatureTime
      , sqAuthorization = Nothing 
      , sqBody = Nothing
      , sqStringToSign = stringToSign
      , sqContentType = Nothing
      , sqContentMd5 = Nothing
      , sqAmzHeaders = []
      , sqOtherHeaders = []
      }
    where
      method = PostQuery
      path = "/"
      expandedQuery = sortBy (comparing fst) 
                       ( snsQuery ++ [ ("AWSAccessKeyId", Just(accessKeyID signatureCredentials)), 
                       ("Expires", Just(BC.pack expiresString)),
                       ("SignatureMethod", Just("HmacSHA256")), ("SignatureVersion",Just("2")), ("Version",Just("2010-03-31")),
                       ("TopicArn", fmap (T.encodeUtf8 . printTopicArn) snsTopicArn)
                       ])
      
      expires = AbsoluteExpires $ snsDefaultExpiry `addUTCTime` signatureTime

      expiresString = formatTime defaultTimeLocale "%FT%TZ" (fromAbsoluteTimeInfo expires)

      sig = signature signatureCredentials HmacSHA256 stringToSign
      stringToSign = Blaze.toByteString . mconcat . intersperse (Blaze8.fromChar '\n') . concat  $
                       [[Blaze.copyByteString $ httpMethod method]
                       , [Blaze.copyByteString $ endpointHost snsEndpoint]
                       , [Blaze.copyByteString $ path]
                       , [Blaze.copyByteString $ HTTP.renderQuery False expandedQuery ]]

      signedQuery = expandedQuery ++ (HTTP.simpleQueryToQuery $ makeAuthQuery)

      makeAuthQuery = [("Signature", sig)]

snsResponseConsumer :: HTTPResponseConsumer a
                    -> IORef SnsMetadata
                    -> HTTPResponseConsumer a
snsResponseConsumer inner metadata resp = do
      let headerString = fmap T.decodeUtf8 . flip lookup (HTTP.responseHeaders resp)
      let requestId = headerString "x-amz-request-id"

      let m = SnsMetadata { snsMRequestId = requestId }
      liftIO $ tellMetadataRef metadata m

      if HTTP.responseStatus resp >= HTTP.status400
        then snsErrorResponseConsumer resp
        else inner resp

snsXmlResponseConsumer :: (Cu.Cursor -> Response SnsMetadata a)
                       -> IORef SnsMetadata
                       -> HTTPResponseConsumer a
snsXmlResponseConsumer parse metadataRef = snsResponseConsumer (xmlCursorConsumer parse metadataRef) metadataRef

snsErrorResponseConsumer :: HTTPResponseConsumer a
snsErrorResponseConsumer resp
    = do doc <- HTTP.responseBody resp $$+- XML.sinkDoc XML.def
         let cursor = Cu.fromDocument doc
         liftIO $ case parseError cursor of
           Success err -> C.monadThrow err
           Failure otherErr -> C.monadThrow otherErr
    where
      parseError :: Cu.Cursor -> Attempt SnsError
      parseError root = do cursor <- force "Missing Error" $ root $/ Cu.laxElement "Error"
                           code <- force "Missing error Code" $ cursor $/ elContent "Code"
                           message <- force "Missing error Message" $ cursor $/ elContent "Message"
                           errorType <- force "Missing error Type" $ cursor $/ elContent "Type"
                           let detail = listToMaybe $ cursor $/ elContent "Detail"
                           return SnsError {
                                        snsStatusCode = HTTP.responseStatus resp
                                      , snsErrorCode = code
                                      , snsErrorMessage = message
                                      , snsErrorType = errorType
                                      , snsErrorDetail = detail
                                      , snsErrorMetadata = Nothing
                                      }

newtype TopicArn = TopicArn { printTopicArn :: T.Text } deriving(Show)