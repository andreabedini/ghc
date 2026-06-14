module GHC.Utils.Touch (touch) where

import GHC.Prelude

import GHC.Platform.Host.Ops (theHostOps, hostTouch)

-- | Set the mtime of the given file to the current time.
touch :: FilePath -> IO ()
touch = hostTouch theHostOps
