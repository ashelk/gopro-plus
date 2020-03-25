{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

module GoPro.Plus where

import           Control.Applicative    (liftA3)
import           Control.Lens
import           Control.Monad          (void)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Aeson             (FromJSON (..), Options (..),
                                         ToJSON (..), Value (..),
                                         defaultOptions, fieldLabelModifier,
                                         genericParseJSON, genericToEncoding,
                                         genericToJSON, (.:))
import qualified Data.Aeson             as J
import           Data.Aeson.Lens
import           Data.Aeson.Types       (typeMismatch)
import qualified Data.ByteString.Char8  as BC
import qualified Data.ByteString.Lazy   as BL
import           Data.Char              (toUpper)
import qualified Data.Map.Strict        as Map
import qualified Data.Text              as T
import           Data.Time.Clock        (UTCTime)
import           Data.Time.Clock.POSIX  (getCurrentTime)
import qualified Data.Vector            as V
import           Generics.Deriving.Base (Generic)
import           Network.Wreq           (FormParam (..), Options, asJSON,
                                         defaults, deleteWith, getWith, header,
                                         params, postWith, putWith,
                                         responseBody)
import           System.FilePath.Posix  (takeExtension, takeFileName)
import           System.IO              (Handle, IOMode (..), SeekMode (..),
                                         hSeek, hTell, withFile)
import           System.Random          (getStdRandom, randomR)

userAgent :: BC.ByteString
userAgent = "github.com/dustin/gopro 0.1"

defOpts :: Network.Wreq.Options
defOpts = defaults & header "User-Agent" .~ [userAgent]

apiClientID, apiClientSecret :: String
apiClientID = "71611e67ea968cfacf45e2b6936c81156fcf5dbe553a2bf2d342da1562d05f46"
apiClientSecret = "3863c9b438c07b82f39ab3eeeef9c24fefa50c6856253e3f1d37e0e3b1ead68d"

authURL :: String
authURL = "https://api.gopro.com/v1/oauth2/token"

authOpts :: String -> Network.Wreq.Options
authOpts tok = defOpts & header "Authorization" .~ ["Bearer " <> BC.pack tok]
               & header "Accept" .~ ["application/vnd.gopro.jk.media+json; version=2.0.0"]
               & header "Content-Type" .~ ["application/json"]

type Token = String

jsonOpts :: Data.Aeson.Options
jsonOpts = defaultOptions {
  fieldLabelModifier = dropWhile (== '_')
  }

-- | An Authentication response.
data AuthResponse = AuthResponse {
  _access_token    :: String
  , _expires_in    :: Int
  , _refresh_token :: String
  } deriving(Generic, Show)

instance FromJSON AuthResponse where
  parseJSON = genericParseJSON jsonOpts

makeLenses ''AuthResponse

authenticate :: MonadIO m => Token -> String -> m AuthResponse
authenticate username password = do
  r <- liftIO (asJSON =<< postWith defOpts authURL ["grant_type" := ("password" :: String),
                                                    "client_id" := apiClientID,
                                                    "client_secret" := apiClientSecret,
                                                    "scope" := ("root root:channels public me upload media_library_beta live" :: String),
                                                    "username" := username,
                                                    "password" := password])
  pure $ r ^. responseBody

-- | Refresh authentication credentials using a refresh token.
refreshAuth :: MonadIO m => AuthResponse -> m AuthResponse
refreshAuth AuthResponse{..} = do
  r <- liftIO ( asJSON =<< postWith defOpts authURL ["grant_type" := ("refresh_token" :: String),
                                                     "client_id" := apiClientID,
                                                     "client_secret" := apiClientSecret,
                                                     "refresh_token" := _refresh_token])
  pure $ r ^. responseBody

data PageInfo = PageInfo {
  _current_page :: Int,
  _per_page     :: Int,
  _total_items  :: Int,
  _total_pages  :: Int
  } deriving (Generic, Show)

makeLenses ''PageInfo

instance FromJSON PageInfo where
  parseJSON = genericParseJSON jsonOpts

{-
failure
transcoding
uploading
-}

data Media = Media {
  _media_id              :: String,
  _media_camera_model    :: Maybe String,
  _media_captured_at     :: UTCTime,
  _media_created_at      :: UTCTime,
  _media_file_size       :: Maybe Int,
  _media_moments_count   :: Int,
  _media_ready_to_view   :: String,
  _media_source_duration :: Maybe String,
  _media_type            :: String,
  _media_token           :: String,
  _media_width           :: Maybe Int,
  _media_height          :: Maybe Int
  } deriving (Generic, Show)

makeLenses ''Media

dropPrefix :: String -> (String -> String)
dropPrefix s = drop (length s)

mediaMod :: String -> String
mediaMod              = dropPrefix "_media_"

instance ToJSON Media where
  toEncoding = genericToEncoding jsonOpts{ fieldLabelModifier = mediaMod}
  toJSON = genericToJSON jsonOpts{ fieldLabelModifier = mediaMod}

instance FromJSON Media where
  parseJSON = genericParseJSON jsonOpts{ fieldLabelModifier = mediaMod}

-- | Get the thumbnail token for a given media result.
thumbnailURL :: Int -> Media -> String
thumbnailURL n Media{_media_token} = "https://images-0" <> show n <> ".gopro.com/resize/450wwp/" <> _media_token

-- | Proxy a request to GoPro with authentication.
proxy :: MonadIO m => Token -> String -> m BL.ByteString
proxy tok u = do
  r <- liftIO $ getWith (authOpts tok) u
  pure $ r ^. responseBody

-- | Fetch thumbnail data for the given media.
fetchThumbnail :: MonadIO m => Token -> Media -> m BL.ByteString
fetchThumbnail tok m = do
  n <- liftIO $ getStdRandom (randomR (1,4))
  proxy tok (thumbnailURL n m)

data Listing = Listing {
  _media :: [Media],
  _pages :: PageInfo
  } deriving (Generic, Show)

makeLenses ''Listing

instance FromJSON Listing where
  parseJSON (Object v) = do
    o <- v .: "_embedded"
    m <- o .: "media"
    ms <- traverse parseJSON (V.toList m)
    Listing ms <$> v .: "_pages"
  parseJSON invalid    = typeMismatch "Response" invalid


jget :: (MonadIO m, FromJSON a) => Token -> String -> m a
jget tok = jgetWith (authOpts tok)

jgetWith :: (MonadIO m, FromJSON a) => Network.Wreq.Options -> String -> m a
jgetWith opts u = view responseBody <$> liftIO (getWith opts u >>= asJSON)

-- | List a page worth of media.
list :: MonadIO m => Token -> Int -> Int -> m ([Media], PageInfo)
list tok psize page = do
  r <- jget tok ("https://api.gopro.com/media/search?fields=captured_at,created_at,file_size,id,moments_count,ready_to_view,source_duration,type,token,width,height,camera_model&order_by=created_at&per_page=" <> show psize <> "&page=" <> show page)
  pure $ (r ^.. media . folded,
          r ^. pages)

-- | List all media.
listAll :: MonadIO m => Token -> m [Media]
listAll tok = listWhile tok (const True)

-- | List all media while returned batches pass the given predicate.
listWhile :: MonadIO m => Token -> ([Media] -> Bool) -> m [Media]
listWhile tok f = do
  Map.elems <$> dig 0 mempty
    where
      dig n m = do
        (ms, _) <- list tok 100 n
        let m' = Map.union m . Map.fromList . map (\md@Media{..} -> (_media_id, md)) $ ms
        if (not . null) ms && f ms
          then dig (n + 1) m'
          else pure m'


data File = File {
  _file_camera_position :: String,
  _file_height          :: Int,
  _file_width           :: Int,
  _file_item_number     :: Int,
  _file_orientation     :: Int,
  _file_url             :: String
  } deriving (Generic, Show)

makeLenses  ''File

instance FromJSON File where
  parseJSON = genericParseJSON defaultOptions {
    fieldLabelModifier = dropPrefix "_file_"
    }

data Variation = Variation {
  _var_height  :: Int,
  _var_width   :: Int,
  _var_label   :: String,
  _var_quality :: String,
  _var_type    :: String,
  _var_url     :: String
  } deriving(Generic, Show)

makeLenses ''Variation

instance FromJSON Variation where
  parseJSON = genericParseJSON defaultOptions {
  fieldLabelModifier = dropPrefix "_var_"
  }

data SpriteFrame = SpriteFrame {
  _frame_count  :: Int,
  _frame_height :: Int,
  _frame_width  :: Int
  } deriving(Generic, Show)

makeLenses ''SpriteFrame

instance FromJSON SpriteFrame where
  parseJSON = genericParseJSON defaultOptions {
    fieldLabelModifier = dropPrefix "_frame_"
  }

data Sprite = Sprite {
  _sprite_fps    :: Double,
  _sprite_frame  :: SpriteFrame,
  _sprite_height :: Int,
  _sprite_width  :: Int,
  _sprite_type   :: String,
  _sprite_urls   :: [String]
  } deriving (Generic, Show)

instance FromJSON Sprite where
  parseJSON = genericParseJSON defaultOptions {
    fieldLabelModifier = dropPrefix "_sprite_"
  }

data FileStuff = FileStuff {
  _files         :: [File],
  _variations    :: [Variation],
  _sprites       :: [Sprite],
  _sidecar_files :: [Value]
  } deriving (Generic, Show)

makeLenses ''FileStuff

instance FromJSON FileStuff where
  parseJSON = genericParseJSON jsonOpts

data FileInfo = FileInfo {
  _fileStuff :: FileStuff,
  _filename  :: String
  } deriving (Generic, Show)

makeLenses ''FileInfo

instance FromJSON FileInfo where
  parseJSON (Object v) = do
    o <- v .: "_embedded"
    fs <- parseJSON o
    FileInfo fs <$> v .: "filename"
  parseJSON invalid    = typeMismatch "Response" invalid

dlURL :: String -> String
dlURL k = "https://api.gopro.com/media/" <> k <> "/download"

-- | Retrieve stuff describing a file.
retrieve :: MonadIO m => Token -> String -> m FileInfo
retrieve tok k = jget tok (dlURL k)

data Error = Error {
  _error_reason      :: String,
  _error_code        :: Int,
  _error_description :: String,
  _error_id          :: String
  } deriving (Generic, Show)

makeLenses ''Error

instance FromJSON Error where
  parseJSON = genericParseJSON defaultOptions {
    fieldLabelModifier = dropPrefix "_error_"
  }

newtype Errors = Errors [Error] deriving (Show)

instance FromJSON Errors where
  parseJSON (Object v) = do
    o <- v .: "_embedded"
    e <- o .: "errors"
    Errors <$> parseJSON e
  parseJSON invalid    = typeMismatch "Response" invalid

-- | Delete an item.
delete :: MonadIO m => Token -> String -> m [Error]
delete tok k = do
  let u = "https://api.gopro.com/media?ids=" <> k
  Errors r <- view responseBody <$> liftIO (deleteWith (authOpts tok) u >>= asJSON)
  pure r

mediumURL :: String -> String
mediumURL = ("https://api.gopro.com/media/" <>)

rawMedium :: MonadIO m => Token -> String -> m Value
rawMedium tok mid = jget tok (mediumURL mid)

putRawMedium :: MonadIO m => Token -> String -> Value -> m Value
putRawMedium tok mid v = view responseBody <$> liftIO (putWith (authOpts tok) (mediumURL mid) v >>= asJSON)

uploadFile :: MonadIO m => Token -> String -> FilePath -> m ()
uploadFile tok uid fp = liftIO $ withFile fp ReadMode $ \fh -> do
  hSeek fh SeekFromEnd 0
  fileSize <- hTell fh
  hSeek fh AbsoluteSeek 0

  let fn = takeFileName fp
      ext = T.pack . fmap toUpper . drop 1 . takeExtension $ fn
      m1 = J.Object (mempty & at "file_extension" ?~ J.String ext
                     & at "filename" ?~ J.String (T.pack fn)
                     & at "type" ?~ J.String (fileType ext)
                     & at "on_public_profile" ?~ J.Bool False
                     & at "content_title" ?~ J.String (T.pack fn)
                     & at "content_source" ?~ J.String "web_media_library"
                     & at "access_token" ?~ J.String (T.pack tok)
                     & at "gopro_user_id" ?~ J.String (T.pack uid))
  cr <- jpostWith "https://api.gopro.com/media" m1

  let Just mid = cr ^? key "id" . _String
      d1 = J.Object (mempty & at "medium_id" ?~ J.String mid
                     & at "file_extension" ?~ J.String ext
                     & at "type" ?~ J.String "Source"
                     & at "label" ?~ J.String "Source"
                     & at "available" ?~ J.Bool False
                     & at "item_count" ?~ J.Number 1
                     & at "camera_positions" ?~ J.String "default"
                     & at "on_public_profile" ?~ J.Bool False
                     & at "access_token" ?~ J.String (T.pack tok)
                     & at "gopro_user_id" ?~ J.String (T.pack uid))
  dr <- jpostWith "https://api.gopro.com/derivatives" d1

  let Just did = dr ^? key "id" . _String
      u1 = J.Object (mempty & at "derivative_id" ?~ J.String did
                     & at "camera_position" ?~ J.String "default"
                     & at "item_number" ?~ J.Number 1
                     & at "access_token" ?~ J.String (T.pack tok)
                     & at "gopro_user_id" ?~ J.String (T.pack uid))
  ur <- jpostWith "https://api.gopro.com/user-uploads" u1

  let Just upid = ur ^? key "id" . _String
      upopts = authOpts tok & params .~ [("id", upid),
                                         ("page", "1"),
                                         ("per_page", "100"),
                                         ("item_number", "1"),
                                         ("camera_position", "default"),
                                         ("file_size", (T.pack . show) fileSize),
                                         ("part_size", (T.pack . show) chunkSize)]
                            & header "Accept" .~  ["application/vnd.gopro.jk.user-uploads+json; version=2.0.0"]
  upaths <- (jgetWith upopts (T.unpack ("https://api.gopro.com/user-uploads/" <> did))) :: IO Value
  let Just ups = upaths ^? key "_embedded" . key "authorizations" . _Array . to V.toList

  mapM_ (uploadOne fh) ups

  let u2 = J.Object (mempty & at "id" ?~ J.String upid
                     & at "item_number" ?~ J.Number 1
                     & at "camera_position" ?~ J.String "default"
                     & at "complete" ?~ J.Bool True
                     & at "derivative_id" ?~ J.String did
                     & at "file_size" ?~ J.String ((T.pack . show) fileSize)
                     & at "part_size" ?~ J.String ((T.pack . show) chunkSize))
  _ <- putWith popts (T.unpack ("https://api.gopro.com/user-uploads/" <> did)) u2

  let d2 = J.Object (mempty & at "available" ?~ J.Bool True
                     & at "access_token" ?~ J.String (T.pack tok)
                     & at "gopro_user_id" ?~ J.String (T.pack uid))

  _ <- putWith popts (T.unpack ("https://api.gopro.com/derivatives/" <> did)) d2

  now <- getCurrentTime
  let done = J.Object (mempty & at "upload_completed_at" ?~ toJSON now
                       & at "client_updated_at" ?~ toJSON now
                       & at "revision_number" ?~ J.Number 0
                       & at "access_token" ?~ J.String (T.pack tok)
                       & at "gopro_user_id" ?~ J.String (T.pack uid))

  void $ putWith popts (T.unpack ("https://api.gopro.com/media/" <> mid)) done

  where
    chunkSize :: Integer
    chunkSize = 6291456

    fileType "JPG" = "Photo"
    fileType _     = "Video"

    popts = authOpts tok & header "Origin" .~ ["https://plus.gopro.com/"]
                         & header "Referer" .~ ["https://plus.gopro.com/media-library"]
                         & header "Accept" .~  ["application/vnd.gopro.jk.user-uploads+json; version=2.0.0"]

    jpostWith :: String -> J.Value -> IO J.Value
    jpostWith u v = view responseBody <$> (asJSON =<< postWith popts u v)

    tInt :: T.Text -> Integer
    tInt = read . T.unpack

    uploadOne :: Handle -> J.Value -> IO ()
    uploadOne fh v = do
      let Just (l, p, u) = liftA3 (,,) (v ^? key "Content-Length" . _String . to tInt)
                                       (v ^? key "part" . _Integer . to toInteger)
                                       (v ^? key "url" . _String . to T.unpack)

          offs = (p - 1) * chunkSize
      hSeek fh AbsoluteSeek offs
      dat <- BL.hGet fh (fromIntegral l)
      void $ putWith defOpts u dat
