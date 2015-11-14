{-# LANGUAGE FlexibleInstances #-}
module TestUtil where

import Control.Monad (liftM, forM_)
import Data.Bits ((.&.), (.|.))
import qualified Data.ByteString.Lazy as B
import qualified Data.Map.Strict as M
import qualified System.Posix.Files.ByteString as PFB
import qualified System.Posix.Files as PF
import qualified System.Posix.Types as PT
import qualified System.Posix.User as PU
import qualified DedupBackup as DDB
import DedupBackup ((//))
import System.Directory (createDirectoryIfMissing)
import Test.Framework
import Test.QuickCheck.Arbitrary (Arbitrary, arbitrary)
import Test.QuickCheck.Gen (oneof)

-- We want to be able to do testing as a regular user, so we'll construct our
-- examples using a UID/GID that we actually control. @unsafePerformIO@ lets
-- us have constants, rather than having to thread the IO monad through
-- everything to get a value that's never going to change.
import System.IO.Unsafe (unsafePerformIO)
{-# NOINLINE effectiveUID #-}
effectiveUID = unsafePerformIO PU.getEffectiveUserID
{-# NOINLINE effectiveGID #-}
effectiveGID = unsafePerformIO PU.getEffectiveGroupID

data FileStatus = FileStatus { mode  :: PT.FileMode
                             , owner :: PT.UserID
                             , group :: PT.GroupID
                             , atime :: PT.EpochTime
                             , ctime :: PT.EpochTime
                             , size  :: PT.FileOffset
                             } deriving(Show)

fromDDBFileStatus :: (DDB.FileStatus a) => a -> FileStatus
fromDDBFileStatus s = FileStatus { mode  = DDB.fileMode s
                                 , owner = DDB.fileOwner s
                                 , group = DDB.fileGroup s
                                 , atime = DDB.accessTime s
                                 , ctime = DDB.modificationTime s
                                 , size  = DDB.fileSize s
                                 }

assertSame :: (Eq a, Show a) => a -> a -> Bool
assertSame x y = if x == y then True else
    error $ show x ++ "\n    /=\n"  ++ show y

instance Arbitrary FileStatus where
    arbitrary = do
        rawStatus <- FileStatus <$>     return PFB.ownerModes
                                    <*> return effectiveUID
                                    <*> return effectiveGID
                                    <*> return 0
                                    <*> return 0
                                    <*> return 0
        typeMode <- oneof $ map return [ PFB.directoryMode
                                       , PFB.regularFileMode
                                       , PFB.symbolicLinkMode
                                       ]
        sizeNum <- arbitrary
        let size = if typeMode == PFB.symbolicLinkMode then
                fromInteger ((sizeNum `mod` 64) + 1)
            else
                fromInteger (sizeNum `mod` maxFileSize)
        return rawStatus { mode = PFB.unionFileModes (mode rawStatus) typeMode
                         , size = size
                         }
      where maxFileSize = 32 * 1024

instance DDB.FileStatus FileStatus where
    isRegularFile s  = PFB.fileTypeModes .&. (mode s) == PFB.regularFileMode
    isDirectory s    = PFB.fileTypeModes .&. (mode s) == PFB.directoryMode
    isSymbolicLink s = PFB.fileTypeModes .&. (mode s) == PFB.symbolicLinkMode
    fileMode         = mode
    fileOwner        = owner
    fileGroup        = group
    accessTime       = atime
    modificationTime = ctime
    fileSize         = size

sampleFileNames = map (:[]) ['a'..'z']
mkName = oneof $ map return sampleFileNames

-- | Write the given tree out to the filesystem. Unlike the effects of
-- @doAction@, this doesn't require an existing file tree somewhere else.
-- This makes it possible to use @writeTree@ with a randomly generated
-- value (from quickcheck).
--
-- Note that there is some missing information that is normally pulled from the
-- src directory. We fill it in as follows:
--
-- * The contents of the file are all zeros, with a size matching that
--   specified by the status.
-- * Symlinks always link to a file whose name consists of '#' characters,
--   and is of the right length to match the status's size.
writeTree :: (DDB.FileStatus s) => FilePath -> DDB.FileTree s -> IO ()
writeTree path (DDB.Directory status contents) = do
    createDirectoryIfMissing True path
    forM_ (M.toList contents) (\(name, subtree) ->
        writeTree (path // name) subtree)
    DDB.syncMetadata path status
writeTree path (DDB.RegularFile status) = do
    let contents = B.pack $ replicate (fromIntegral $ DDB.fileSize status) 0
    B.writeFile path contents
    DDB.syncMetadata path status
writeTree path (DDB.Symlink status) = do
    let targetName = replicate (fromIntegral $ DDB.fileSize status) '#'
    PF.createSymbolicLink targetName path
    DDB.syncMetadata path status


instance Arbitrary (DDB.FileTree FileStatus) where
    arbitrary = do
        status <- arbitrary
        if DDB.isDirectory status then do
            contents <- arbitrary
            return $ DDB.Directory
                        status
                        (M.fromList (zip sampleFileNames contents))
        else if DDB.isRegularFile status then
            return $ DDB.RegularFile status
        else if DDB.isSymbolicLink status then
            return $ DDB.Symlink status
        else
            error "BUG: Unrecogized file type!"

-- We could make a functor instance, but it's not incredibly natural for the
-- FileStatus to be the "value" per se, and we don't really need the generality.
mapStatus :: (a -> b) -> DDB.FileTree a -> DDB.FileTree b
mapStatus f (DDB.Symlink s) = DDB.Symlink (f s)
mapStatus f (DDB.RegularFile s) = DDB.RegularFile (f s)
mapStatus f (DDB.Directory s c) = DDB.Directory (f s) (M.map (mapStatus f) c)

instance Eq FileStatus where
    l == r = and $ [ fileType l == fileType r
                   , DDB.fileOwner l == DDB.fileOwner r
                   , DDB.fileGroup l == DDB.fileGroup r
                   , DDB.isSymbolicLink l ||
                        and [ access l == access r
                            , DDB.modificationTime l == DDB.modificationTime r
                            , DDB.accessTime l == DDB.accessTime r
                            ]
                   , DDB.isDirectory l || DDB.fileSize l == DDB.fileSize r
                   ]
        where
          access status = DDB.fileMode status .&. PFB.accessModes
          fileType status = DDB.fileMode status .&. PFB.fileTypeModes
