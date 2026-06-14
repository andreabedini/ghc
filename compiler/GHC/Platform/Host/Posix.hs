-- | POSIX implementation of the host operations declared in
-- "GHC.Platform.Host.Ops". Selected on non-Windows hosts. Bodies here are moved
-- verbatim from their original (POSIX) @#ifdef@ branches in the compiler.
module GHC.Platform.Host.Posix
  ( getProcessID
  ) where

import GHC.Prelude

import qualified System.Posix.Internals

-- | (POSIX branch moved verbatim from "GHC.Utils.TmpFs".)
getProcessID :: IO Int
getProcessID = System.Posix.Internals.c_getpid >>= return . fromIntegral
