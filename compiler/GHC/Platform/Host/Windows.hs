-- | Windows implementation of the host operations declared in
-- "GHC.Platform.Host.Ops". Selected on Windows hosts. Bodies here are moved
-- verbatim from their original (Windows) @#ifdef@ branches in the compiler.
module GHC.Platform.Host.Windows
  ( getProcessID
  ) where

import GHC.Prelude (IO, Int)

-- | (Windows branch moved verbatim from "GHC.Utils.TmpFs".)
-- Relies on @Int == Int32@ on Windows.
foreign import ccall unsafe "_getpid" getProcessID :: IO Int
