module GHC.Driver.Config.CmmToLlvm
  ( initLlvmCgConfig
  , llvmTargetFeatureList
  )
where

import GHC.Prelude
import GHC.Driver.DynFlags
import GHC.Driver.LlvmConfigCache
import GHC.Platform
import GHC.CmmToLlvm.Config
import GHC.CmmToLlvm.Version.Type (LlvmVersion(..))
import GHC.SysTools.Tasks

import GHC.Utils.Outputable
import GHC.Utils.Logger

import Data.List.NonEmpty ( NonEmpty(..) )

-- | Initialize the Llvm code generator configuration from DynFlags
initLlvmCgConfig :: Logger -> LlvmConfigCache -> DynFlags -> IO LlvmCgConfig
initLlvmCgConfig logger config_cache dflags = do
  version <- figureLlvmVersion logger dflags
  llvm_config <- readLlvmConfigCache config_cache
  pure $! LlvmCgConfig {
    llvmCgPlatform               = targetPlatform dflags
    , llvmCgContext              = initSDocContext dflags PprCode
    , llvmCgFillUndefWithGarbage = gopt Opt_LlvmFillUndefWithGarbage dflags
    , llvmCgSplitSection         = gopt Opt_SplitSections dflags
    , llvmCgBmiVersion           = case platformArch (targetPlatform dflags) of
                                      ArchX86_64 -> bmiVersion dflags
                                      ArchX86    -> bmiVersion dflags
                                      _          -> Nothing
    , llvmCgLlvmVersion          = version
    , llvmCgDoWarn               = wopt Opt_WarnUnsupportedLlvmVersion dflags
    , llvmCgLlvmTarget           = platformMisc_llvmTarget $! platformMisc dflags
    , llvmCgLlvmConfig           = llvm_config
    , llvmCgTargetFeatures       = llvmTargetFeatureList dflags version
    }

-- | The LLVM target features implied by the current 'DynFlags'.
--
-- Two consumers: the @-mattr@ passed to @llc@ and @opt@
-- ('GHC.Driver.Pipeline.Execute.llvmOptions'), and the per-procedure
-- @\"target-features\"@ attribute.  The latter replaces @-mattr@ for that
-- function, so both have to come from the same list.
-- See Note [Cmm target attributes] in GHC.Cmm.
llvmTargetFeatureList :: DynFlags -> Maybe LlvmVersion -> [String]
llvmTargetFeatureList dflags llvm_version =
       ["+sse4.2"  | isSse4_2Enabled dflags   ]
    ++ ["+popcnt"  | isSse4_2Enabled dflags   ]
         -- LLVM gates POPCNT instructions behind the popcnt flag,
         -- while the GHC NCG (as well as GCC, Clang) gates it
         -- behind SSE4.2 instead.
    ++ ["+sse4.1"  | isSse4_1Enabled dflags   ]
    ++ ["+ssse3"   | isSsse3Enabled dflags    ]
    ++ ["+sse3"    | isSse3Enabled dflags     ]
    ++ ["+sse2"    | isSse2Enabled platform   ]
    ++ ["+sse"     | isSseEnabled platform    ]
    ++ ["+avx512f" | isAvx512fEnabled dflags  ]
    ++ ["+evex512" | isAvx512fEnabled dflags, evex512_ok ]
         -- +evex512 is recognized by LLVM 18 or newer and needed on macOS
         -- (#26410).  It may become deprecated in a future LLVM version.
    ++ ["+avx2"    | isAvx2Enabled dflags     ]
    ++ ["+avx"     | isAvxEnabled dflags      ]
    ++ ["+avx512bw"| isAvx512bwEnabled dflags ]
    ++ ["+avx512cd"| isAvx512cdEnabled dflags ]
    ++ ["+avx512dq"| isAvx512dqEnabled dflags ]
    ++ ["+avx512er"| isAvx512erEnabled dflags ]
    ++ ["+avx512pf"| isAvx512pfEnabled dflags ]
    ++ ["+avx512vl"| isAvx512vlEnabled dflags ]
    -- For AArch64 +fma is not an option (it's unconditionally available).
    ++ ["+fma"     | isFmaEnabled dflags && (arch /= ArchAArch64) ]
    ++ ["+bmi"     | isBmiEnabled dflags      ]
    ++ ["+bmi2"    | isBmi2Enabled dflags     ]
    ++ ["+gfni"    | isGfniEnabled dflags     ]
  where
    platform = targetPlatform dflags
    arch     = platformArch platform
    evex512_ok = maybe False (>= LlvmVersion (18 :| [])) llvm_version
