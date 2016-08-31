{-|
Module      : Test.Aeson.Internal.GoldenSpecs
Description : Golden tests for Arbitrary
Copyright   : (c) Plow Technologies, 2016
License     : BSD3
Maintainer  : mchaver@gmail.com
Stability   : Beta

Internal module, use at your own risk.
-}

{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Aeson.Internal.GoldenSpecs where

import           Control.Exception
import           Control.Monad

import           Data.Aeson
import           Data.Aeson.Encode.Pretty
import           Data.ByteString.Lazy hiding (putStrLn)
import           Data.Proxy
import           Data.Typeable

import           Prelude hiding (readFile, writeFile)

import           System.Directory
import           System.FilePath
import           System.Random

import           Test.Aeson.Internal.RandomSamples
import           Test.Aeson.Internal.Utils
import           Test.Hspec
import           Test.QuickCheck

-- | Tests to ensure that JSON encoding has not unintentionally changed. This
-- could be caused by the following:
--
-- - A type's instances of `ToJSON` or 'FromJSON' have changed.
-- - Selectors have been edited, added or deleted.
-- - You have changed version of Aeson the way Aeson serialization has changed
--   works.
--
-- If you run this function and the golden files do not
-- exist, it will create them for each constructor. It they do exist, it will
-- compare with golden file if it exists. Golden file encodes json format of a
-- type. It is recommended that you put the golden files under revision control
-- to help monitor changes.
goldenSpecs :: (Eq a, Show a, Typeable a, Arbitrary a, ToJSON a, FromJSON a) =>
  Settings -> Proxy a -> Spec
goldenSpecs settings proxy = goldenSpecsWithNote settings proxy Nothing

-- | same as 'goldenSpecs' but has the option of passing a note to the
-- 'describe' function.
goldenSpecsWithNote :: forall a. (Eq a, Show a, Typeable a, Arbitrary a, ToJSON a, FromJSON a) =>
  Settings -> Proxy a -> Maybe String -> Spec
goldenSpecsWithNote settings@Settings{..} proxy mNote = do
  mModuleName <-
    if useModuleNameAsSubDirectory
      then return Nothing
      else do
        arbA <- runIO $ generate (arbitrary :: Gen a)
        return $ Just $ show . tyConModule . typeRepTyCon . typeOf $ arbA

  let goldenFile = mkGoldenFile topDir mModuleName proxy
      note = maybe "" (" " ++) mNote

  describe ("JSON encoding of " ++ addBrackets (show (typeRep proxy)) ++ note) $
    it ("produces the same JSON as is found in " ++ goldenFile) $ do
      exists <- doesFileExist goldenFile
      if exists
        then compareWithGolden topDir mModuleName proxy goldenFile
        else createGoldenfile settings proxy goldenFile
  where
    topDir = case goldenDirectoryOption of
      GoldenDirectory -> "golden"
      CustomDirectoryName d -> d

-- | The golden files already exist. Serialize values with the same seed from
-- the golden file and compare the with the JSON in the golden file.
compareWithGolden :: forall a .
  (Eq a, Show a, Typeable a, Arbitrary a, ToJSON a, FromJSON a) =>
  FilePath -> Maybe FilePath -> Proxy a -> FilePath -> IO ()
compareWithGolden topDir mModuleName proxy goldenFile = do
  goldenSeed <- readSeed =<< readFile goldenFile
  sampleSize <- readSampleSize =<< readFile goldenFile
  newSamples <- mkRandomSamples sampleSize proxy goldenSeed
  whenFails (writeComparisonFile newSamples) $ do
    goldenSamples :: RandomSamples a <-
      either (throwIO . ErrorCall) return =<<
      eitherDecode' <$>
      readFile goldenFile
    newSamples `shouldBe` goldenSamples
  where
    whenFails :: forall b c . IO c -> IO b -> IO b
    whenFails = flip onException

    faultyFile = mkFaultyFile topDir mModuleName proxy

    writeComparisonFile newSamples = do
      writeFile faultyFile (encodePretty newSamples)
      putStrLn $
        "\n" ++
        "INFO: Written the current encodings into " ++ faultyFile ++ "."

-- | The golden files do not exist. Create it.
createGoldenfile :: forall a . (Show a, Arbitrary a, ToJSON a) =>
  Settings -> Proxy a -> FilePath -> IO ()
createGoldenfile Settings{..} proxy goldenFile = do
  createDirectoryIfMissing True (takeDirectory goldenFile)
  rSeed <- randomIO
  rSamples <- mkRandomSamples sampleSize proxy rSeed
  writeFile goldenFile (encodePretty rSamples)

  putStrLn $
    "\n" ++
    "WARNING: Running for the first time, not testing anything.\n" ++
    "  Created " ++ goldenFile ++ " containing random samples,\n" ++
    "  will compare JSON encodings with this from now on.\n" ++
    "  Please, consider putting " ++ goldenFile ++ " under version control."

-- | Create the file path for the golden file. Optionally use the module name to
-- help avoid name collissions. Different modules can have types of the same
-- name.
mkGoldenFile :: Typeable a => FilePath -> Maybe FilePath -> Proxy a -> FilePath
mkGoldenFile topDir mModuleName proxy =
  case mModuleName of
    Nothing         -> topDir </> show (typeRep proxy) <.> "json"
    Just moduleName -> topDir </> moduleName </> show (typeRep proxy) <.> "json"

-- | Create the file path to save results from a failed golden test. Optionally
-- use the module name to help avoid name collisions.  Different modules can
-- have types of the same name.
mkFaultyFile :: Typeable a => FilePath -> Maybe FilePath -> Proxy a -> FilePath
mkFaultyFile topDir mModuleName proxy =
  case mModuleName of
    Nothing         -> topDir </> show (typeRep proxy) <.> "faulty" <.> "json"
    Just moduleName -> topDir </> moduleName </> show (typeRep proxy) <.> "faulty" <.> "json"

-- | Create a number of arbitrary instances of a type
-- a sample size and a random seed.
mkRandomSamples :: forall a . Arbitrary a =>
  Int -> Proxy a -> Int -> IO (RandomSamples a)
mkRandomSamples sampleSize Proxy rSeed = RandomSamples rSeed <$> generate gen
  where
    correctedSampleSize = if sampleSize <= 0 then 1 else sampleSize
    gen :: Gen [a]
    gen = setSeed rSeed $ replicateM correctedSampleSize (arbitrary :: Gen a)
