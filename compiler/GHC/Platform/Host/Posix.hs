-- | POSIX implementation of the host operations declared in
-- "GHC.Platform.Host.Ops". Selected on non-Windows hosts. Bodies here are moved
-- verbatim from their original (POSIX) @#ifdef@ branches in the compiler.
module GHC.Platform.Host.Posix
  ( getProcessID
  , archiveFileInfo
  ) where

import GHC.Prelude

import qualified System.Posix.Internals
import qualified System.Posix.Files as POSIX

-- | (POSIX branch moved verbatim from "GHC.Utils.TmpFs".)
getProcessID :: IO Int
getProcessID = System.Posix.Internals.c_getpid >>= return . fromIntegral

-- | (POSIX branch moved verbatim from "GHC.SysTools.Ar".)
archiveFileInfo :: FilePath -> IO (Int, Int, Int, Int)
archiveFileInfo fp = go <$> POSIX.getFileStatus fp
  where go status = ( fromEnum $ POSIX.modificationTime status
                    , fromIntegral $ POSIX.fileOwner status
                    , fromIntegral $ POSIX.fileGroup status
                    , oct2dec . fromIntegral $ POSIX.fileMode status
                    )

oct2dec :: Int -> Int
oct2dec = foldl' (\a b -> a * 10 + b) 0 . reverse . dec 8
  where dec _ 0 = []
        dec b i = let (rest, last) = i `quotRem` b
                  in last:dec b rest
