{-|
Module      : GoPro.Plus.Auth
Description : Functionality for authenticating to GoPro Plus.
Copyright   : (c) Dustin Sallings, 2020
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

GoPro Plus authentication.
-}

{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeSynonymInstances #-}

module GoPro.Plus.Auth (
  authenticate, refreshAuth,
  AuthInfo(..), access_token, expires_in, refresh_token, resource_owner_id,
  HasGoProAuth(..), withAuth, AuthReader, Token
  ) where

import           Control.Lens
import           Control.Monad.IO.Class   (MonadIO (..))
import           Control.Monad.Reader     (ReaderT (..), ask, runReaderT)
import           Data.Aeson               (FromJSON (..), genericParseJSON)
import           Data.Text                (Text)
import           Generics.Deriving.Base   (Generic)
import           Network.Wreq             (FormParam (..))


import           GoPro.Plus.Internal.HTTP

apiClientID, apiClientSecret :: String
apiClientID = "71611e67ea968cfacf45e2b6936c81156fcf5dbe553a2bf2d342da1562d05f46"
apiClientSecret = "3863c9b438c07b82f39ab3eeeef9c24fefa50c6856253e3f1d37e0e3b1ead68d"

authURL :: String
authURL = "https://api.gopro.com/v1/oauth2/token"

type Token = Text

-- | An Authentication response.
data AuthInfo = AuthInfo {
  _access_token        :: Token
  , _expires_in        :: Int
  , _refresh_token     :: Text
  , _resource_owner_id :: Text
  } deriving(Generic, Show)

class Monad m => HasGoProAuth m where
  goproAuth :: m AuthInfo

instance FromJSON AuthInfo where
  parseJSON = genericParseJSON jsonOpts

makeLenses ''AuthInfo

authenticate :: MonadIO m
             => String -- ^ Email/username
             -> String -- ^ Password
             -> m AuthInfo
authenticate username password =
  jpostWith defOpts authURL ["grant_type" := ("password" :: String),
                             "client_id" := apiClientID,
                             "client_secret" := apiClientSecret,
                             "scope" := ("root root:channels public me upload media_library_beta live" :: String),
                             "username" := username,
                             "password" := password]

-- | Refresh authentication credentials using a refresh token.
refreshAuth :: MonadIO m => AuthInfo -> m AuthInfo
refreshAuth AuthInfo{..} =
  jpostWith defOpts authURL ["grant_type" := ("refresh_token" :: String),
                             "client_id" := apiClientID,
                             "client_secret" := apiClientSecret,
                             "refresh_token" := _refresh_token]

type AuthReader = ReaderT AuthInfo

instance Monad m => HasGoProAuth (AuthReader m) where
  goproAuth = ask

-- | Convenient function for passing around auth info.  You probably
-- don't want to use this, but it can be conven ient when
-- experimenting.
withAuth :: (Monad m, HasGoProAuth m) => AuthInfo -> AuthReader m a -> m a
withAuth = flip runReaderT
