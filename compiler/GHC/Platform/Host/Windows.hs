-- | Windows implementation of the host operations declared in
-- "GHC.Platform.Host.Ops". Selected on Windows hosts. Bodies here are moved
-- verbatim from their original (Windows) @#ifdef@ branches in the compiler.
module GHC.Platform.Host.Windows
  ( getProcessID
  , archiveFileInfo
  , touch
  , mangleGccPathEnv
  ) where

import GHC.Prelude

import Data.Char (toUpper)
import System.Win32.File
import System.Win32.Time

-- | (Windows branch moved verbatim from "GHC.Utils.TmpFs".)
-- Relies on @Int == Int32@ on Windows.
foreign import ccall unsafe "_getpid" getProcessID :: IO Int

-- | (Windows branch moved verbatim from "GHC.SysTools.Ar".)
-- On Windows mod time, owner, group and mode are zero.
archiveFileInfo :: FilePath -> IO (Int, Int, Int, Int)
archiveFileInfo _ = pure (0, 0, 0, 0)

-- | (Windows branch moved verbatim from "GHC.Utils.Touch".)
touch :: FilePath -> IO ()
touch file = do
  hdl <- createFile file gENERIC_WRITE fILE_SHARE_NONE Nothing oPEN_ALWAYS fILE_ATTRIBUTE_NORMAL Nothing
  t <- getSystemTimeAsFileTime
  setFileTime hdl Nothing Nothing (Just t)
  closeHandle hdl

-- | (Windows branch moved verbatim from "GHC.SysTools.Process": work around
-- #1110 by prepending the -B dir to PATH, lest we stumble into #17266.)
mangleGccPathEnv :: [FilePath] -> [(String, String)] -> [(String, String)]
mangleGccPathEnv b_dirs = map mangle_path
  where
    mangle_path (path, paths)
      | map toUpper path == "PATH"
      = (path, '"' : head b_dirs ++ "\";" ++ paths)
    mangle_path other = other
