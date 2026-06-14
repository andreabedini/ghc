{-# LANGUAGE CPP #-}

-- | Host-platform operations.
--
-- This module is the typed interface to the OS-dependent behaviours that the
-- GHC /process/ needs from the machine it runs on (the \"host\", as opposed to
-- the \"target\" it compiles code for — see "GHC.Platform"). Ordinary compiler
-- code should call through 'theHostOps' rather than branching on
-- @*_HOST_OS@\/@*_HOST_ARCH@ itself.
--
-- It is also the single seam where the host OS is selected (the one remaining
-- @#if defined(mingw32_HOST_OS)@, picking the POSIX or Windows implementation;
-- see @docs\/platform-abstraction\/plan.md@ §4.4 option 1). As host @#ifdef@
-- sites in the compiler are migrated (Phase 2 of the plan), each becomes a
-- field of 'HostOps' implemented in "GHC.Platform.Host.Posix" /
-- "GHC.Platform.Host.Windows".
--
-- The host /identity/ (arch\/OS) is provided separately by the generated module
-- "GHC.Platform.Host" (@hostPlatformArchOS@ et al.); host machine-model facts
-- (e.g. word size) are folded in by later phases of the plan.
module GHC.Platform.Host.Ops
  ( HostOps(..)
  , theHostOps
  ) where

import GHC.Prelude

#if defined(mingw32_HOST_OS)
import qualified GHC.Platform.Host.Windows as Impl
#else
import qualified GHC.Platform.Host.Posix as Impl
#endif

-- | The OS-dependent operations the compiler process needs from its host.
--
-- This is a record of operations (a value), mirroring how the target
-- 'GHC.Platform.Platform' is threaded as a value: it can be stored in env\/
-- session records and trivially stubbed in tests. Each field corresponds to a
-- host @#ifdef@ site being migrated out of the body of the compiler; see
-- @docs\/platform-abstraction\/phase0-cpp-classification.md@ for the inventory.
data HostOps = HostOps
  { hostGetProcessID :: IO Int
      -- ^ The id of the current (compiler) process. Was: a @_getpid@ vs
      --   @c_getpid@ split in "GHC.Utils.TmpFs".
  , hostArchiveFileInfo :: FilePath -> IO (Int, Int, Int, Int)
      -- ^ @(modification time, owner, group, mode in decimal)@ for an archive
      --   member; all zero on Windows. Was: a @stat@ vs zeros split in
      --   "GHC.SysTools.Ar".
  , hostTouch :: FilePath -> IO ()
      -- ^ Set the mtime of a file to now. Was: a Win32 vs POSIX split in
      --   "GHC.Utils.Touch".
  , hostMangleGccPathEnv :: [FilePath] -> [(String, String)] -> [(String, String)]
      -- ^ Given the @-B@ directories, adjust a process environment so the C
      --   compiler can find its auxiliary binaries (prepends to @PATH@ on
      --   Windows, identity elsewhere; #1110). Was: an inline split in
      --   "GHC.SysTools.Process".
  , hostStderrSupportsColor :: IO Bool
      -- ^ Whether ANSI colour escape sequences can be used on @stderr@
      --   (terminal probe on POSIX, console-mode/VTP handling on Windows). Was:
      --   a @mingw32@ split in "GHC.SysTools.Terminal".
  , hostInstallSignalHandlers :: IO () -> (Int -> IO ()) -> IO (IO ())
      -- ^ @hostInstallSignalHandlers interrupt fatalSignal@ installs the ^C /
      --   terminate handlers and returns an action that uninstalls them. The
      --   @interrupt@ action handles ^C\/SIGINT\/SIGQUIT; @fatalSignal n@
      --   handles fatal signals (e.g. SIGHUP\/SIGTERM). POSIX signals vs the
      --   Windows console-ctrl handler vs nothing on hosts without @\<signal.h\>@
      --   (e.g. wasm32-wasi). Was: a @mingw32@\/@HAVE_SIGNAL_H@ split in
      --   "GHC.Utils.Panic".
  }

-- | The 'HostOps' for the platform this @ghc@ was built to run on.
--
-- A top-level CAF for now; the plan threads it into the relevant env records as
-- a follow-up.
theHostOps :: HostOps
theHostOps = HostOps
  { hostGetProcessID     = Impl.getProcessID
  , hostArchiveFileInfo  = Impl.archiveFileInfo
  , hostTouch            = Impl.touch
  , hostMangleGccPathEnv = Impl.mangleGccPathEnv
  , hostStderrSupportsColor = Impl.stderrSupportsAnsiColors
  , hostInstallSignalHandlers = Impl.installSignalHandlers
  }
