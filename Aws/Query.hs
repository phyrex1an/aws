{-# LANGUAGE RecordWildCards, OverloadedStrings #-}
module Aws.Query
where

import           Aws.Http
import           Aws.Util
import           Data.Maybe
import           Data.Time
import qualified Blaze.ByteString.Builder as Blaze
import qualified Data.Ascii               as A
import qualified Data.ByteString          as B
import qualified Data.ByteString.Lazy     as L
import qualified Data.ByteString.UTF8     as BU
import qualified Network.HTTP.Enumerator  as HTTP
import qualified Network.HTTP.Types       as HTTP

data SignedQuery 
    = SignedQuery {
        sqMethod :: Method
      , sqProtocol :: Protocol
      , sqHost :: A.Ascii
      , sqPort :: Int
      , sqPath :: A.Ascii
      , sqQuery :: HTTP.Query
      , sqDate :: Maybe UTCTime
      , sqAuthorization :: Maybe A.Ascii
      , sqContentType :: Maybe A.Ascii
      , sqContentMd5 :: Maybe A.Ascii
      , sqBody :: L.ByteString
      , sqStringToSign :: B.ByteString
      }
    deriving (Show)

queryToHttpRequest :: SignedQuery -> HTTP.Request m
queryToHttpRequest SignedQuery{..}
    = HTTP.Request {
        HTTP.method = httpMethod sqMethod
      , HTTP.secure = case sqProtocol of
                        HTTP -> False
                        HTTPS -> True
      , HTTP.checkCerts = const (return True) -- FIXME: actually check certificates
      , HTTP.host = sqHost
      , HTTP.port = sqPort
      , HTTP.path = sqPath
      , HTTP.queryString = sqQuery
      , HTTP.requestHeaders = catMaybes [fmap (\d -> ("Date", fmtRfc822Time d)) sqDate
                                        , fmap (\c -> ("Content-Type", c)) contentType
                                        , fmap (\md5 -> ("Content-MD5", md5)) sqContentMd5
                                        , fmap (\auth -> ("Authorization", auth)) sqAuthorization]
      , HTTP.requestBody = HTTP.RequestBodyLBS $ case sqMethod of
                                                   Get -> L.empty
                                                   PostQuery -> Blaze.toLazyByteString . A.toBuilder $ HTTP.renderQueryBuilder False sqQuery
      }
    where contentType = case sqMethod of
                           PostQuery -> Just "application/x-www-form-urlencoded; charset=utf-8"
                           _ -> sqContentType

queryToUri :: SignedQuery -> B.ByteString
queryToUri SignedQuery{..} 
    = B.concat [
       case sqProtocol of
         HTTP -> "http://"
         HTTPS -> "https://"
      , A.toByteString sqHost
      , if sqPort == defaultPort sqProtocol then "" else BU.fromString $ ':' : show sqPort
      , A.toByteString sqPath
      , A.toByteString $ HTTP.renderQuery True sqQuery
      ]
