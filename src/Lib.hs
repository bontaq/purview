{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}

module Lib where

import Prelude hiding (div, log)
import qualified Web.Scotty as Sc
import           Data.Text (Text)
import qualified Data.Text.Lazy as LazyText
import           Data.Text.Encoding
import           Data.ByteString.Lazy (ByteString, toStrict)
import           Data.ByteString.Lazy.Char8 (unpack)
import qualified Network.Wai.Middleware.Gzip as Sc
import qualified Network.Wai.Handler.WebSockets as WaiWs
import qualified Network.WebSockets as WS
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import           Data.Aeson
import           GHC.Generics

import           Component
import           Wrapper

text :: String -> Html a
text = Text

html :: Tag -> [Attribute a] -> [Html a] -> Html a
html = Html

onClick :: a -> Attribute a
onClick = OnClick

style :: ByteString -> Attribute a
style = Style

div :: [Attribute a] -> [Html a] -> Html a
div = Html "div"

defaultComponent :: Component (a -> a) b
defaultComponent = Component
  { state    = id
  , handlers = const
  , render   = \_state -> Html "p" [] [text "default"]
  }

--
-- Handling for connecting, sending events, and replacing html
--
-- For now it's nothing fancy with a single event binding on the
-- top level <html> element, which I copied from phoenix live view.
--
-- Definitely easier than dealing with binding/unbinding when updating
-- the html.
--

renderComponent :: Show a => Html a -> ByteString
renderComponent = runRender

type Log m = String -> m ()

run :: Show a => Log IO -> Html a -> IO ()
run log routes = do
  let port = 8001
  let settings = Warp.setPort port Warp.defaultSettings
  requestHandler' <- requestHandler routes
  Warp.runSettings settings
    $ WaiWs.websocketsOr
        WS.defaultConnectionOptions
        (webSocketHandler log routes)
        requestHandler'

requestHandler :: Show a => Html a -> IO Wai.Application
requestHandler routes =
  Sc.scottyApp $ do
    Sc.middleware $ Sc.gzip $ Sc.def { Sc.gzipFiles = Sc.GzipCompress }
    --Sc.middleware S.logStdoutDev

    Sc.get "/" $ Sc.html $ LazyText.fromStrict $ wrapHtml $ (decodeUtf8 . toStrict $ renderComponent routes)

data Event = Event
  { event :: Text
  , message :: Text
  } deriving (Generic, Show)

data FromEvent = FromEvent
  { event :: Text
  , message :: Value
  }

instance FromJSON FromEvent where
  parseJSON (Object o) =
      FromEvent <$> o .: "event" <*> (o .: "message")
  parseJSON _ = error "fail"

instance ToJSON Event where
  toEncoding = genericToEncoding defaultOptions

--
-- This is the main event loop of handling messages from the websocket
--
-- pretty much just get a message, then run the message via the component
-- handler, and then send the "setHtml" back downstream to tell it to replace
-- the html with the new.
--
looper :: Show a => Log IO -> WS.Connection -> Html a -> IO ()
looper log conn component = do
  msg <- WS.receiveData conn
  log $ "\x1b[34;1mreceived>\x1b[0m " <> unpack msg

  let
    decoded = decode msg :: Maybe FromEvent
    newTree = case decoded of
      Just (FromEvent _ message) -> handle component message
      Nothing -> component

    newHtml = renderComponent newTree

  log $ "\x1b[32;1msending>\x1b[0m " <> show newHtml

  WS.sendTextData
    conn
    (encode $ Event { event = "setHtml", message = decodeUtf8 . toStrict $ newHtml })

  looper log conn newTree


webSocketHandler :: Show a => Log IO -> Html a -> WS.ServerApp
webSocketHandler log component pending = do
  putStrLn "ws connected"
  conn <- WS.acceptRequest pending

  WS.withPingThread conn 30 (pure ()) $ do
    looper log conn component
