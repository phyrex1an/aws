module Aws.Sns.Commands.Publish where

import           Aws.Core
import           Aws.Sns.Core
import           Control.Applicative
import           Data.Maybe
import           Text.XML.Cursor       (($/), ($//), (&/), (&|))
import qualified Control.Failure       as F
import qualified Data.ByteString.Char8 as B
import qualified Data.Text             as T
import qualified Data.Text.Encoding    as TE
import qualified Text.XML.Cursor       as Cu


data Publish = Publish
    { pMessage :: T.Text
    , pMessageStructure :: MessageStructure
    , pSubject :: T.Text
    , pTopicArn :: TopicArn
    }

data MessageStructure = MSText | MSJSON

data PublishResponse = PublishResponse
    { prMessageId :: T.Text
    }

instance ResponseConsumer r PublishResponse where
    type ResponseMetadata PublishResponse = SnsMetadata
    responseConsumer _ = snsXmlResponseConsumer parse
        where
          parse el = do
            prid <- force "Missing Response Id" $ el $// Cu.laxElement "MessageId" &/ Cu.content
            return PublishResponse { prMessageId = prid }

instance SignQuery Publish where
    type ServiceConfiguration Publish = SnsConfiguration
    signQuery Publish {..} = snsSignQuery SnsQuery
                           { snsQuery = [("Action", Just "Publish"),
                                         ("Message", Just $ TE.encodeUtf8 pMessage)
                                        ]
                           , snsTopicArn = Just pTopicArn
                           }

instance Transaction Publish PublishResponse

instance AsMemoryResponse PublishResponse where
    type MemoryResponse PublishResponse = PublishResponse
    loadToMemory = return