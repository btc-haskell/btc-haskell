{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
--Module      : Haskoin.Test.Util
--Copyright   : No rights reserved
--License     : MIT
--Maintainer  : jprupp@protonmail.ch
--Stability   : experimental
--Portability : POSIX
module Haskoin.Util.Arbitrary.Util (
    arbitraryBS,
    arbitraryBS1,
    arbitraryBSn,
    arbitraryBSS,
    arbitraryBSS1,
    arbitraryBSSn,
    arbitraryMaybe,
    arbitraryNetwork,
    arbitraryUTCTime,
    SerialBox (..),
    ReadBox (..),
    testSerial,
    testRead,
    arbitraryNetData,
    genNetData,
) where

import Control.Monad (forM_, (<=<))
import Data.ByteString (ByteString, pack)
import Data.ByteString.Lazy (fromStrict, toStrict)
import qualified Data.ByteString.Short as BSS
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Bytes.Serial
import qualified Data.Map.Strict as Map
import Data.Proxy
import Data.Time.Clock (UTCTime (..))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import qualified Data.Typeable as T
import Data.Word (Word32)
import Haskoin.Constants
import Haskoin.Data
import Test.Hspec (Spec, describe, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck


-- | Arbitrary strict 'ByteString'.
arbitraryBS :: Gen ByteString
arbitraryBS = pack <$> arbitrary


-- | Arbitrary non-empty strict 'ByteString'
arbitraryBS1 :: Gen ByteString
arbitraryBS1 = pack <$> listOf1 arbitrary


-- | Arbitrary strict 'ByteString' of a given length
arbitraryBSn :: Int -> Gen ByteString
arbitraryBSn n = pack <$> vectorOf n arbitrary


-- | Arbitrary 'ShortByteString'.
arbitraryBSS :: Gen BSS.ShortByteString
arbitraryBSS = BSS.pack <$> arbitrary


-- | Arbitrary non-empty 'ShortByteString'
arbitraryBSS1 :: Gen BSS.ShortByteString
arbitraryBSS1 = BSS.pack <$> listOf1 arbitrary


-- | Arbitrary 'ShortByteString' of a given length
arbitraryBSSn :: Int -> Gen BSS.ShortByteString
arbitraryBSSn n = BSS.pack <$> vectorOf n arbitrary


-- | Arbitrary UTCTime that generates dates after 01 Jan 1970 01:00:00 CET
arbitraryUTCTime :: Gen UTCTime
arbitraryUTCTime = do
    w <- arbitrary :: Gen Word32
    return $ posixSecondsToUTCTime $ realToFrac w


-- | Generate a Maybe from a Gen a
arbitraryMaybe :: Gen a -> Gen (Maybe a)
arbitraryMaybe g =
    frequency
        [ (1, return Nothing)
        , (5, Just <$> g)
        ]


-- | Generate an Network
arbitraryNetwork :: Gen Network
arbitraryNetwork = elements allNets


-- Helpers for creating Serial and JSON Identity tests

data SerialBox
    = forall a.
        (Show a, Eq a, T.Typeable a, Serial a) =>
      SerialBox (Gen a)


data ReadBox
    = forall a.
        (Read a, Show a, Eq a, T.Typeable a) =>
      ReadBox (Gen a)


-- | Generate binary identity tests
testSerial ::
    (Eq a, Show a, T.Typeable a, Serial a) => Gen a -> Spec
testSerial gen =
    prop ("Binary encoding/decoding identity for " <> name) $
        forAll gen $ \x -> do
            (runGetL deserialize . runPutL . serialize) x `shouldBe` x
            (runGetL deserialize . fromStrict . runPutS . serialize) x `shouldBe` x
            (runGetS deserialize . runPutS . serialize) x `shouldBe` Right x
            (runGetS deserialize . toStrict . runPutL . serialize) x `shouldBe` Right x
    where
        name = show $ T.typeRep $ proxy gen
        proxy :: Gen a -> Proxy a
        proxy = const Proxy


-- | Generate Read/Show identity tests
testRead ::
    (Eq a, Read a, Show a, T.Typeable a) => Gen a -> Spec
testRead gen =
    prop ("read/show identity for " <> name) $
        forAll gen $ \x -> (read . show) x `shouldBe` x
    where
        name = show $ T.typeRep $ proxy gen
        proxy :: Gen a -> Proxy a
        proxy = const Proxy


arbitraryNetData :: Arbitrary a => Gen (Network, a)
arbitraryNetData = do
    net <- arbitraryNetwork
    x <- arbitrary
    return (net, x)


genNetData :: Gen a -> Gen (Network, a)
genNetData gen = do
    net <- arbitraryNetwork
    x <- gen
    return (net, x)


toMap :: a -> Map.Map String a
toMap = Map.singleton "object"


fromMap :: Map.Map String a -> a
fromMap = (Map.! "object")
