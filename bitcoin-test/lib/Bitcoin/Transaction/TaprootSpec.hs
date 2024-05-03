{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Bitcoin.Transaction.TaprootSpec (spec) where

import Bitcoin (
    MAST (..),
    PubKeyI (PubKeyI),
    PubKeyXO,
    PubKeyXY,
    ScriptOutput,
    ScriptPathData (..),
    TaprootOutput (TaprootOutput),
    TaprootWitness (ScriptPathSpend),
    addrToText,
    btc,
    decodeHex,
    encodeTaprootWitness,
    getMerkleProofs,
    importPubKeyXO,
    importPubKeyXY,
    mastCommitment,
    outputAddress,
    taprootInternalKey,
    taprootMAST,
    taprootOutputKey,
    taprootScriptOutput,
    verifyScriptPathData,
    xyToXO,
 )
import Bitcoin.Orphans ()
import qualified Bitcoin.Util as U
import Bitcoin.UtilSpec (readTestFile)
import Control.Applicative ((<|>))
import Control.Monad (zipWithM, (<=<))
import Data.Aeson (FromJSON (parseJSON), withObject, (.:), (.:?))
import Data.Aeson.Types (Parser)
import qualified Data.ByteArray as BA
import Data.ByteArray.Encoding
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word8)
import Test.HUnit (assertBool, (@?=))
import Test.Hspec (Spec, describe, it, runIO)


spec :: Spec
spec = do
    TestVector{testScriptPubKey} <- runIO $ readTestFile "bip341.json"
    describe "Taproot" $ do
        it "should calculate the correct hashes" $ mapM_ testHashes testScriptPubKey
        it "should build the correct output key" $ mapM_ testOutputKey testScriptPubKey
        it "should build the correct script output" $ mapM_ testScriptOutput testScriptPubKey
        it "should calculate the correct control blocks" $ mapM_ testControlBlocks testScriptPubKey
        it "should arrive at the correct address" $ mapM_ testAddress testScriptPubKey


testHashes :: TestScriptPubKey -> IO ()
testHashes testData =
    mapM_ checkMASTDetails $ (taprootMAST . tspkGiven) testData
  where
    checkMASTDetails theMAST = do
        -- Leaf hashes
        (Just . getLeafHashes) theMAST @?= (spkiLeafHashes . tspkIntermediary) testData
        -- Merkle root
        (Just . BA.convert . mastCommitment) theMAST @?= (spkiMerkleRoot . tspkIntermediary) testData

    getLeafHashes = \case
        MASTBranch branchL branchR -> getLeafHashes branchL <> getLeafHashes branchR
        leaf@MASTLeaf{} -> [BA.convert $ mastCommitment leaf]
        MASTCommitment{} -> mempty -- The test vectors have complete trees


testOutputKey :: TestScriptPubKey -> IO ()
testOutputKey testData = do
    (fst . xyToXO) (taprootOutputKey theOutput) @?= theOutputKey
  where
    theOutput = tspkGiven testData
    theOutputKey = spkiTweakedPubKey $ tspkIntermediary testData


testScriptOutput :: TestScriptPubKey -> IO ()
testScriptOutput testData =
    taprootScriptOutput (tspkGiven testData) @?= (spkeScriptPubKey . tspkExpected) testData


testControlBlocks :: TestScriptPubKey -> IO ()
testControlBlocks testData = do
    mapM_ (onExamples . fmap (convertToBase Base16)) exampleControlBlocks
    mapM_ checkVerification scriptPathSpends
  where
    theOutput = tspkGiven testData
    theOutputKey = taprootOutputKey theOutput
    exampleControlBlocks = spkeControlBlocks $ tspkExpected testData
    calculatedControlBlocks =
        (!! 1) . encodeTaprootWitness . ScriptPathSpend <$> scriptPathSpends
    scriptPathSpends =
        fmap mkScriptPathSpend
            . maybe mempty getMerkleProofs
            $ taprootMAST theOutput
    mkScriptPathSpend (scriptPathLeafVersion, scriptPathScript, proof) =
        ScriptPathData
            { scriptPathAnnex = Nothing
            , scriptPathStack = mempty
            , scriptPathScript
            , scriptPathExternalIsOdd = snd . xyToXO $ theOutputKey
            , scriptPathLeafVersion
            , scriptPathInternalKey = taprootInternalKey theOutput
            , scriptPathControl = BA.convert <$> proof
            }
    onExamples = zipWithM (@?=) (fmap (convertToBase @ByteString @ByteString Base16) calculatedControlBlocks)
    checkVerification = assertBool "Script verifies" . verifyScriptPathData theOutputKey


testAddress :: TestScriptPubKey -> IO ()
testAddress testData = computedAddress @?= (Just . spkeAddress . tspkExpected) testData
  where
    computedAddress = (addrToText btc <=< outputAddress) . taprootScriptOutput $ tspkGiven testData


newtype SpkGiven = SpkGiven {unSpkGiven :: TaprootOutput}


instance FromJSON SpkGiven where
    parseJSON = withObject "SpkGiven" $ \obj ->
        fmap SpkGiven $
            TaprootOutput
                <$> (maybe (fail "Invalid Public Key") pure . (importPubKeyXO <=< decodeHex) =<< obj .: "internalPubkey")
                <*> (obj .:? "scriptTree" >>= traverse parseScriptTree)
      where
        parseScriptTree v =
            parseScriptLeaf v
                <|> parseScriptBranch v
                <|> fail "Unable to parse scriptTree"
        parseScriptLeaf = withObject "ScriptTree leaf" $ \obj ->
            MASTLeaf
                <$> obj .: "leafVersion"
                <*> (obj .: "script" >>= hexScript)
        parseScriptBranch v =
            parseJSON v >>= \case
                [v1, v2] -> MASTBranch <$> parseScriptTree v1 <*> parseScriptTree v2
                _ -> fail "ScriptTree branch"
        hexScript = either fail pure . U.decode . BSL.fromStrict <=< jsonHex


data SpkIntermediary = SpkIntermediary
    { spkiLeafHashes :: Maybe [ByteString]
    , spkiMerkleRoot :: Maybe ByteString
    , spkiTweakedPubKey :: PubKeyXO
    }


instance FromJSON SpkIntermediary where
    parseJSON = withObject "SpkIntermediary" $ \obj ->
        SpkIntermediary
            <$> (obj .:? "leafHashes" >>= (traverse . traverse) jsonHex)
            <*> (obj .: "merkleRoot" >>= traverse jsonHex)
            <*> (obj .: "tweakedPubkey" >>= maybe (fail "Invalid Public Key") pure . (importPubKeyXO <=< decodeHex))


data SpkExpected = SpkExpected
    { spkeScriptPubKey :: ScriptOutput
    , spkeControlBlocks :: Maybe [ByteString]
    , spkeAddress :: Text
    }


instance FromJSON SpkExpected where
    parseJSON = withObject "SpkExpected" $ \obj ->
        SpkExpected
            <$> obj .: "scriptPubKey"
            <*> (obj .:? "scriptPathControlBlocks" >>= (traverse . traverse) jsonHex)
            <*> obj .: "bip350Address"


data TestScriptPubKey = TestScriptPubKey
    { tspkGiven :: TaprootOutput
    , tspkIntermediary :: SpkIntermediary
    , tspkExpected :: SpkExpected
    }


instance FromJSON TestScriptPubKey where
    parseJSON = withObject "TestScriptPubKey" $ \obj ->
        TestScriptPubKey
            <$> (unSpkGiven <$> obj .: "given")
            <*> obj .: "intermediary"
            <*> obj .: "expected"


newtype TestVector = TestVector
    { testScriptPubKey :: [TestScriptPubKey]
    }


instance FromJSON TestVector where
    parseJSON = withObject "TestVector" $ \obj ->
        TestVector <$> obj .: "scriptPubKey"


jsonHex :: Text -> Parser ByteString
jsonHex = maybe (fail "Unable to decode hex") pure . decodeHex
