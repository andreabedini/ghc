module GHC.SysTools.Terminal (stderrSupportsAnsiColors) where

import GHC.Prelude

import GHC.Platform.Host.Ops (theHostOps, hostStderrSupportsColor)

import System.IO.Unsafe

-- | Does the controlling terminal support ANSI color sequences?
-- This memoized to avoid thread-safety issues in ncurses (see #17922).
--
-- The actual probe (terminal detection on POSIX, console-mode/VTP handling on
-- Windows) is delegated to the host abstraction; see "GHC.Platform.Host.Ops".
stderrSupportsAnsiColors :: Bool
stderrSupportsAnsiColors = unsafePerformIO (hostStderrSupportsColor theHostOps)
{-# NOINLINE stderrSupportsAnsiColors #-}
