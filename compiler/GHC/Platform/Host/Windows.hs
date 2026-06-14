{-# LANGUAGE ScopedTypeVariables #-}

-- | Windows implementation of the host operations declared in
-- "GHC.Platform.Host.Ops". Selected on Windows hosts. Bodies here are moved
-- verbatim from their original (Windows) @#ifdef@ branches in the compiler.
module GHC.Platform.Host.Windows
  ( getProcessID
  , archiveFileInfo
  , touch
  , mangleGccPathEnv
  , stderrSupportsAnsiColors
  ) where

import GHC.Prelude

import Data.Char (toUpper)
import System.Win32.File
import System.Win32.Time

import GHC.IO (catchException)
import GHC.Utils.Exception (try)
import Foreign (Ptr, peek, with)
import qualified Graphics.Win32 as Win32
import qualified System.Win32 as Win32

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

-- | (Windows branch moved verbatim from "GHC.SysTools.Terminal".)
-- Check if ANSI escape sequences can be used to control colour on @stderr@.
stderrSupportsAnsiColors :: IO Bool
stderrSupportsAnsiColors = do
  h <- Win32.getStdHandle Win32.sTD_ERROR_HANDLE
         `catchException` \ (_ :: IOError) ->
           pure Win32.nullHANDLE
  if h == Win32.nullHANDLE
    then pure False
    else do
      eMode <- try (getConsoleMode h)
      case eMode of
        Left (_ :: IOError) -> Win32.isMinTTYHandle h
                                 -- Check if the we're in a MinTTY terminal
                                 -- (e.g., Cygwin or MSYS2)
        Right mode
          | modeHasVTP mode -> pure True
          | otherwise       -> enableVTP h mode

  where

    enableVTP :: Win32.HANDLE -> Win32.DWORD -> IO Bool
    enableVTP h mode = do
        setConsoleMode h (modeAddVTP mode)
        modeHasVTP <$> getConsoleMode h
      `catchException` \ (_ :: IOError) ->
        pure False

    modeHasVTP :: Win32.DWORD -> Bool
    modeHasVTP mode = mode .&. eNABLE_VIRTUAL_TERMINAL_PROCESSING /= 0

    modeAddVTP :: Win32.DWORD -> Win32.DWORD
    modeAddVTP mode = mode .|. eNABLE_VIRTUAL_TERMINAL_PROCESSING

eNABLE_VIRTUAL_TERMINAL_PROCESSING :: Win32.DWORD
eNABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

getConsoleMode :: Win32.HANDLE -> IO Win32.DWORD
getConsoleMode h = with 64 $ \ mode -> do
  Win32.failIfFalse_ "GetConsoleMode" (c_GetConsoleMode h mode)
  peek mode

setConsoleMode :: Win32.HANDLE -> Win32.DWORD -> IO ()
setConsoleMode h mode = do
  Win32.failIfFalse_ "SetConsoleMode" (c_SetConsoleMode h mode)

foreign import ccall unsafe "windows.h GetConsoleMode" c_GetConsoleMode
  :: Win32.HANDLE -> Ptr Win32.DWORD -> IO Win32.BOOL

foreign import ccall unsafe "windows.h SetConsoleMode" c_SetConsoleMode
  :: Win32.HANDLE -> Win32.DWORD -> IO Win32.BOOL
