{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ViewPatterns      #-}

-- Module      : Network.AWS.Credentials
-- Copyright   : (c) 2013-2014 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Network.AWS.Credentials
    (
    -- * Loading credentials
      Credentials (..)
    , credentials

    -- * Defaults
    , accessKey
    , secretKey
    ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Error
import           Control.Exception          (throwIO)
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.Aeson                 as Aeson
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.IORef
import           Data.Monoid
import           Data.String
import           Data.Text                  (Text)
import qualified Data.Text                  as Text
import qualified Data.Text.Encoding         as Text
import           Data.Time
import           Network.AWS.Data
import           Network.AWS.EC2.Metadata
import           Network.AWS.Error
import           Network.AWS.Types
import           System.Environment

-- | Default access key environment variable: 'AWS_ACCESS_KEY'
accessKey :: ByteString
accessKey = "AWS_ACCESS_KEY"

-- | Default secret key environment variable: 'AWS_SECRET_KEY'
secretKey :: ByteString
secretKey = "AWS_SECRET_KEY"

data Credentials
    = FromKeys ByteString ByteString
      -- ^ Explicit access and secret keys.
    | FromSession ByteString ByteString ByteString
      -- ^ A session containing the access key, secret key, and a security token.
    | FromProfile ByteString
      -- ^ An IAM Profile name to lookup from the local EC2 instance-data.
    | FromEnv ByteString ByteString
      -- ^ Environment variables to lookup for the access and secret keys.
    | Discover
      -- ^ Attempt to read the default access and secret keys from the environment,
      -- falling back to the first available IAM profile if they are not set.
      --
      -- This attempts to resolve <http://instance-data> rather than directly
      -- retrieving <http://169.254.169.254> for IAM profile information to ensure
      -- the dns lookup terminates promptly if not running on EC2.
      deriving (Eq, Ord)

instance ToByteString Credentials where
    toByteString (FromKeys    a _)   = "FromKeys "    <> a <> " ****"
    toByteString (FromSession a _ _) = "FromSession " <> a <> " **** ****"
    toByteString (FromProfile n)     = "FromProfile " <> n
    toByteString (FromEnv     a s)   = "FromEnv "     <> a <> " " <> s
    toByteString Discover            = "Discover"

instance Show Credentials where
    show = showByteString

credentials :: MonadIO m => Credentials -> EitherT Error m AuthRef
credentials c = case c of
    FromKeys    a s   -> newRef $ Auth a s Nothing Nothing
    FromSession a s t -> newRef $ Auth a s (Just t) Nothing
    FromProfile n     -> fromProfile n
    FromEnv     a s   -> fromKeys a s >>= newRef
    Discover -> (fromKeys accessKey secretKey >>= newRef)
        `catchT` const (defaultProfile >>= fromProfile)
 where
    fromKeys a s = Auth
        <$> key a
        <*> key s
        <*> pure Nothing
        <*> pure Nothing

    key (Text.unpack -> k) = do
        m <- liftIO $ lookupEnv k
        maybe (throwT . Error $ "Unable to read ENV variable: " ++ k)
              (return . BS.pack)
              m

defaultProfile :: MonadIO m => EitherT Error m ByteString
defaultProfile = do
    !ls <- BS.lines <$> meta (IAM $ SecurityCredentials Nothing)
    tryHead "Unable to get default IAM Profile from metadata" ls

-- | The IONewRef wrapper + timer is designed so that multiple concurrenct
-- accesses of 'Auth' from the 'AWS' environment are not required to calculate
-- expiry and sequentially queue to update it.
--
-- The forked timer ensures a singular owner and pre-emptive refresh of the
-- temporary session credentials.
fromProfile :: MonadIO m => ByteString -> EitherT Error m AuthRef
fromProfile name = do
    !a@Auth{..} <- auth
    runIO $ do
        r <- newRef a
        start r authExpiry
        return r
  where
    auth :: MonadIO m => EitherT Error m Auth
    auth = do
        m <- LBS.fromStrict `liftM` meta iam
        hoistEither . fmapL fromString $ Aeson.eitherDecode m

    iam = IAM . SecurityCredentials $ Just name

    start r = maybe (return ()) (timer r <=< delay)

    delay n = truncate . diffUTCTime n <$> getCurrentTime

    -- FIXME:
    --  guard against a lower expiration than the -60
    --  remove the error . show shenanigans
    timer r n = void . forkIO $ do
        threadDelay $ (n - 60) * 1000000
        !a@Auth{..} <- eitherT throwIO return auth
        atomicWriteIORef (authRef r) a
        start r authExpiry

newRef :: MonadIO m => Auth -> m AuthRef
newRef = liftM AuthRef . liftIO . newIORef
