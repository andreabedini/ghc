{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE UnliftedDatatypes #-}
{-# LANGUAGE UnliftedFFITypes #-}

module Main where

import Data.Functor
import Debug.Trace
import GHC.Exts
import GHC.Exts.Heap
import GHC.Exts.Heap (getBoxedClosureData)
import GHC.Exts.Heap.Closures
import GHC.Exts.Heap.Closures (GenStackFrame (retFunFun), StackField)
import GHC.Exts.Stack
import GHC.Exts.Stack.Decode
import GHC.IO (IO (..))
import GHC.Stack (HasCallStack)
import GHC.Stack.CloneStack (StackSnapshot (..))
import System.Info
import System.Mem
import TestUtils
import Unsafe.Coerce (unsafeCoerce)

foreign import prim "any_update_framezh" any_update_frame# :: SetupFunction

foreign import prim "any_catch_framezh" any_catch_frame# :: SetupFunction

foreign import prim "any_catch_stm_framezh" any_catch_stm_frame# :: SetupFunction

foreign import prim "any_catch_retry_framezh" any_catch_retry_frame# :: SetupFunction

foreign import prim "any_atomically_framezh" any_atomically_frame# :: SetupFunction

foreign import prim "any_ret_small_prim_framezh" any_ret_small_prim_frame# :: SetupFunction

foreign import prim "any_ret_small_prims_framezh" any_ret_small_prims_frame# :: SetupFunction

foreign import prim "any_ret_small_closure_framezh" any_ret_small_closure_frame# :: SetupFunction

foreign import prim "any_ret_small_closures_framezh" any_ret_small_closures_frame# :: SetupFunction

foreign import prim "any_ret_big_prims_min_framezh" any_ret_big_prims_min_frame# :: SetupFunction

foreign import prim "any_ret_big_closures_min_framezh" any_ret_big_closures_min_frame# :: SetupFunction

foreign import prim "any_ret_big_closures_two_words_framezh" any_ret_big_closures_two_words_frame# :: SetupFunction

foreign import prim "any_ret_fun_arg_n_prim_framezh" any_ret_fun_arg_n_prim_frame# :: SetupFunction

foreign import prim "any_ret_fun_arg_gen_framezh" any_ret_fun_arg_gen_frame# :: SetupFunction

foreign import prim "any_ret_fun_arg_gen_big_framezh" any_ret_fun_arg_gen_big_frame# :: SetupFunction

foreign import prim "any_bco_framezh" any_bco_frame# :: SetupFunction

foreign import prim "any_underflow_framezh" any_underflow_frame# :: SetupFunction

foreign import ccall "maxSmallBitmapBits" maxSmallBitmapBits_c :: Word

foreign import ccall "bitsInWord" bitsInWord :: Word

{- Test stategy
   ~~~~~~~~~~~~

- Create @StgStack@s in C that contain two frames: A stop frame and the frame
which's decoding should be tested.

- Cmm primops are used to get `StackSnapshot#` values. (This detour ensures that
the closures are referenced by `StackSnapshot#` and not garbage collected right
away.)

- These can then be decoded and checked.

This strategy may look pretty complex for a test. But, it can provide very
specific corner cases that would be hard to (reliably!) produce in Haskell.

N.B. `StackSnapshots` are managed by the garbage collector. It's important to
know that the GC may rewrite parts of the stack and that the stack must be sound
(otherwise, the GC may fail badly.) To find subtle garbage collection related
bugs, the GC is triggered several times.

The decission to make `StackSnapshots`s (and their closures) being managed by the
GC isn't accidential. It's closer to the reality of decoding stacks.

N.B. the test data stack are only meant be de decoded. They are not executable
(the result would likely be a crash or non-sense.)

- Due to the implementation details of the test framework, the Debug.Trace calls
are only shown when the test fails. They are used as markers to see where the
test fails on e.g. a segfault (where the HasCallStack constraint isn't helpful.)
-}
main :: HasCallStack => IO ()
main = do
  traceM "Test 1"
  test any_update_frame# $
    \case
      UpdateFrame {..} -> do
        assertEqual (tipe info_tbl) UPDATE_FRAME
        assertEqual 1 =<< getWordFromBlackhole updatee
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 2"
  testSize any_update_frame# 2
  traceM "Test 3"
  test any_catch_frame# $
    \case
      CatchFrame {..} -> do
        assertEqual (tipe info_tbl) CATCH_FRAME
        assertConstrClosure 1 handler
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 4"
  testSize any_catch_frame# 2
  traceM "Test 5"
  test any_catch_stm_frame# $
    \case
      CatchStmFrame {..} -> do
        assertEqual (tipe info_tbl) CATCH_STM_FRAME
        assertConstrClosure 1 catchFrameCode
        assertConstrClosure 2 handler
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 6"
  testSize any_catch_stm_frame# 3
  traceM "Test 7"
  test any_catch_retry_frame# $
    \case
      CatchRetryFrame {..} -> do
        assertEqual (tipe info_tbl) CATCH_RETRY_FRAME
        assertEqual running_alt_code 1
        assertConstrClosure 2 first_code
        assertConstrClosure 3 alt_code
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 8"
  testSize any_catch_retry_frame# 4
  traceM "Test 9"
  test any_atomically_frame# $
    \case
      AtomicallyFrame {..} -> do
        assertEqual (tipe info_tbl) ATOMICALLY_FRAME
        assertConstrClosure 1 atomicallyFrameCode
        assertConstrClosure 2 result
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 10"
  testSize any_atomically_frame# 3
  traceM "Test 11"
  test any_ret_small_prim_frame# $
    \case
      RetSmall {..} -> do
        assertEqual (tipe info_tbl) RET_SMALL
        assertEqual (length stack_payload) 1
        assertUnknownTypeWordSizedPrimitive 1 (head stack_payload)
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 12"
  testSize any_ret_small_prim_frame# 2
  traceM "Test 13"
  test any_ret_small_closure_frame# $
    \case
      RetSmall {..} -> do
        assertEqual (tipe info_tbl) RET_SMALL
        assertEqual (length stack_payload) 1
        assertConstrClosure 1 $ (stackFieldClosure . head) stack_payload
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 14"
  testSize any_ret_small_closure_frame# 2
  traceM "Test 15"
  test any_ret_small_closures_frame# $
    \case
      RetSmall {..} -> do
        assertEqual (tipe info_tbl) RET_SMALL
        assertEqual (length stack_payload) maxSmallBitmapBits
        wds <- mapM (getWordFromConstr01 . stackFieldClosure) stack_payload
        assertEqual wds [1 .. maxSmallBitmapBits]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 16"
  testSize any_ret_small_closures_frame# (1 + fromIntegral maxSmallBitmapBits_c)
  traceM "Test 17"
  test any_ret_small_prims_frame# $
    \case
      RetSmall {..} -> do
        assertEqual (tipe info_tbl) RET_SMALL
        assertEqual (length stack_payload) maxSmallBitmapBits
        let wds = map stackFieldWord stack_payload
        assertEqual wds [1 .. maxSmallBitmapBits]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 18"
  testSize any_ret_small_prims_frame# (1 + fromIntegral maxSmallBitmapBits_c)
  traceM "Test 19"
  test any_ret_big_prims_min_frame# $
    \case
      RetBig {..} -> do
        assertEqual (tipe info_tbl) RET_BIG
        assertEqual (length stack_payload) minBigBitmapBits
        let wds = map stackFieldWord stack_payload
        assertEqual wds [1 .. minBigBitmapBits]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 20"
  testSize any_ret_big_prims_min_frame# (minBigBitmapBits + 1)
  traceM "Test 21"
  test any_ret_big_closures_min_frame# $
    \case
      RetBig {..} -> do
        assertEqual (tipe info_tbl) RET_BIG
        assertEqual (length stack_payload) minBigBitmapBits
        wds <- mapM (getWordFromConstr01 . stackFieldClosure) stack_payload
        assertEqual wds [1 .. minBigBitmapBits]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 22"
  testSize any_ret_big_closures_min_frame# (minBigBitmapBits + 1)
  traceM "Test 23"
  test any_ret_big_closures_two_words_frame# $
    \case
      RetBig {..} -> do
        assertEqual (tipe info_tbl) RET_BIG
        let closureCount = fromIntegral $ bitsInWord + 1
        assertEqual (length stack_payload) closureCount
        wds <- mapM (getWordFromConstr01 . stackFieldClosure) stack_payload
        assertEqual wds [1 .. (fromIntegral closureCount)]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 24"
  testSize any_ret_big_closures_two_words_frame# (fromIntegral bitsInWord + 1 + 1)
  traceM "Test 25"
  test any_ret_fun_arg_n_prim_frame# $
    \case
      RetFun {..} -> do
        assertEqual (tipe info_tbl) RET_FUN
        assertEqual retFunSize 1
        assertFun01Closure 1 retFunFun
        assertEqual (length retFunPayload) 1
        let wds = map stackFieldWord retFunPayload
        assertEqual wds [1]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 26"
  test any_ret_fun_arg_gen_frame# $
    \case
      RetFun {..} -> do
        assertEqual (tipe info_tbl) RET_FUN
        assertEqual retFunSize 9
        retFunFun' <- getBoxedClosureData retFunFun
        case retFunFun' of
          FunClosure {..} -> do
            assertEqual (tipe info) FUN_STATIC
            assertEqual (null dataArgs) True
            -- Darwin seems to have a slightly different layout regarding
            -- function `argGenFun`
            assertEqual (null ptrArgs) (os /= "darwin")
          e -> error $ "Wrong closure type: " ++ show e
        assertEqual (length retFunPayload) 9
        wds <- mapM (getWordFromConstr01 . stackFieldClosure) retFunPayload
        assertEqual wds [1 .. 9]
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 27"
  testSize any_ret_fun_arg_gen_frame# (3 + 9)
  traceM "Test 28"
  test any_ret_fun_arg_gen_big_frame# $
    \case
      RetFun {..} -> do
        assertEqual (tipe info_tbl) RET_FUN
        assertEqual retFunSize 59
        retFunFun' <- getBoxedClosureData retFunFun
        case retFunFun' of
          FunClosure {..} -> do
            assertEqual (tipe info) FUN_STATIC
            assertEqual (null dataArgs) True
            assertEqual (null ptrArgs) True
          e -> error $ "Wrong closure type: " ++ show e
        assertEqual (length retFunPayload) 59
        wds <- mapM (getWordFromConstr01 . stackFieldClosure) retFunPayload
        assertEqual wds [1 .. 59]
  traceM "Test 29"
  testSize any_ret_fun_arg_gen_big_frame# (3 + 59)
  traceM "Test 30"
  test any_bco_frame# $
    \case
      RetBCO {..} -> do
        assertEqual (tipe info_tbl) RET_BCO
        assertEqual (length bcoArgs) 1
        wds <- mapM (getWordFromConstr01 . stackFieldClosure) bcoArgs
        assertEqual wds [3]
        bco' <- getBoxedClosureData bco
        case bco' of
          BCOClosure {..} -> do
            assertEqual (tipe info) BCO
            assertEqual arity 3
            assertEqual size 7
            assertArrWordsClosure [1] instrs
            assertArrWordsClosure [2] literals
            assertMutArrClosure [3] bcoptrs
            assertEqual
              [ 1, -- StgLargeBitmap size in words
                0 -- StgLargeBitmap first words
              ]
              bitmap
          e -> error $ "Wrong closure type: " ++ show e
      e -> error $ "Wrong closure type: " ++ show e
  traceM "Test 31"
  testSize any_bco_frame# 3
  traceM "Test 32"
  test any_underflow_frame# $
    \case
      UnderflowFrame {..} -> do
        assertEqual (tipe info_tbl) UNDERFLOW_FRAME
        assertEqual (tipe (ssc_info nextChunk)) STACK
        assertEqual (ssc_stack_size nextChunk) 27
        assertEqual (length (ssc_stack nextChunk)) 2
        case head (ssc_stack nextChunk) of
          RetSmall {..} ->
            assertEqual (tipe info_tbl) RET_SMALL
          e -> error $ "Wrong closure type: " ++ show e
        case last (ssc_stack nextChunk) of
          StopFrame {..} ->
            assertEqual (tipe info_tbl) STOP_FRAME
          e -> error $ "Wrong closure type: " ++ show e
      e -> error $ "Wrong closure type: " ++ show e
  testSize any_underflow_frame# 2

type SetupFunction = State# RealWorld -> (# State# RealWorld, StackSnapshot# #)

test :: HasCallStack => SetupFunction -> (StackFrame -> IO ()) -> IO ()
test setup assertion = do
  stackSnapshot <- getStackSnapshot setup
  traceM $ "entertainGC - " ++ entertainGC 10000
  -- Run garbage collection now, to prevent later surprises: It's hard to debug
  -- when the GC suddenly does it's work and there were bad closures or pointers.
  -- Better fail early, here.
  performGC
  stackClosure <- decodeStack stackSnapshot
  traceM $ "entertainGC - " ++ entertainGC 10000
  performGC
  let stack = ssc_stack stackClosure
  performGC
  assert stack
  where
    assert :: [StackFrame] -> IO ()
    assert stack = do
      assertStackInvariants stack
      assertEqual (length stack) 2
      assertion $ head stack

-- | Generate some bogus closures to give the GC work
--
-- There are thresholds in the GC when it starts working. We want to force this
-- to show that the decoding code is GC-save (updated pointers/references are a
-- big topic here as the GC cares about references to the StgStack itself, but
-- not to its frames.)
--
-- The "level of entertainment" x is a bit arbitrarily choosen: A future
-- performace improvement may be to reduce it to a smaller number.
entertainGC :: Int -> String
entertainGC 0 = "0"
entertainGC x = show x ++ entertainGC (x - 1)
{-# NOINLINE entertainGC #-}

testSize :: HasCallStack => SetupFunction -> Int -> IO ()
testSize setup expectedSize = do
  stackSnapshot <- getStackSnapshot setup
  stackClosure <- decodeStack stackSnapshot
  assertEqual expectedSize $ (stackFrameSize . head . ssc_stack) stackClosure

-- | Get a `StackSnapshot` from test setup
--
-- This function mostly resembles `cloneStack`. Though, it doesn't clone, but
-- just pulls a @StgStack@ from RTS to Haskell land.
getStackSnapshot :: SetupFunction -> IO StackSnapshot
getStackSnapshot action# = IO $ \s ->
  case action# s of (# s1, stack #) -> (# s1, StackSnapshot stack #)

assertConstrClosure :: HasCallStack => Word -> Box -> IO ()
assertConstrClosure w c =
  getBoxedClosureData c >>= \case
    ConstrClosure {..} -> do
      assertEqual (tipe info) CONSTR_0_1
      assertEqual dataArgs [w]
      assertEqual (null ptrArgs) True
    e -> error $ "Wrong closure type: " ++ show e

assertArrWordsClosure :: HasCallStack => [Word] -> Box -> IO ()
assertArrWordsClosure wds c =
  getBoxedClosureData c >>= \case
    ArrWordsClosure {..} -> do
      assertEqual (tipe info) ARR_WORDS
      assertEqual arrWords wds
    e -> error $ "Wrong closure type: " ++ show e

assertMutArrClosure :: HasCallStack => [Word] -> Box -> IO ()
assertMutArrClosure wds c =
  getBoxedClosureData c >>= \case
    MutArrClosure {..} -> do
      assertEqual (tipe info) MUT_ARR_PTRS_FROZEN_CLEAN
      assertEqual wds =<< mapM getWordFromConstr01 mccPayload
    e -> error $ "Wrong closure type: " ++ show e

assertFun01Closure :: HasCallStack => Word -> Box -> IO ()
assertFun01Closure w c =
  getBoxedClosureData c >>= \case
    FunClosure {..} -> do
      assertEqual (tipe info) FUN_0_1
      assertEqual dataArgs [w]
      assertEqual (null ptrArgs) True
    e -> error $ "Wrong closure type: " ++ show e

getWordFromConstr01 :: HasCallStack => Box -> IO Word
getWordFromConstr01 c =
  getBoxedClosureData c >>= \case
    ConstrClosure {..} -> pure $ head dataArgs
    e -> error $ "Wrong closure type: " ++ show e

getWordFromBlackhole :: HasCallStack => Box -> IO Word
getWordFromBlackhole c =
  getBoxedClosureData c >>= \case
    BlackholeClosure {..} -> getWordFromConstr01 indirectee
    -- For test stability reasons: Expect that the blackhole might have been
    -- resolved.
    ConstrClosure {..} -> pure $ head dataArgs
    e -> error $ "Wrong closure type: " ++ show e

assertUnknownTypeWordSizedPrimitive :: HasCallStack => Word -> StackField -> IO ()
assertUnknownTypeWordSizedPrimitive w stackField =
  assertEqual (stackFieldWord stackField) w

unboxSingletonTuple :: (# StackSnapshot# #) -> StackSnapshot#
unboxSingletonTuple (# s# #) = s#

minBigBitmapBits :: Num a => a
minBigBitmapBits = 1 + maxSmallBitmapBits

maxSmallBitmapBits :: Num a => a
maxSmallBitmapBits = fromIntegral maxSmallBitmapBits_c

stackFieldClosure :: HasCallStack => StackField -> Box
stackFieldClosure (StackBox b) = b
stackFieldClosure w = error $ "Expected closure in a Box, got: " ++ show w

stackFieldWord :: HasCallStack => StackField -> Word
stackFieldWord (StackWord w) = w
stackFieldWord c = error $ "Expected word, got: " ++ show c

-- | A function with 59 arguments
--
-- A small bitmap has @64 - 6 = 58@ entries on 64bit machines. On 32bit machines
-- it's less (for obvious reasons.) I.e. this function's bitmap a large one;
-- function type is @ARG_GEN_BIG@.
{-# NOINLINE argGenBigFun #-}
argGenBigFun ::
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word
argGenBigFun a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 a27 a28 a29 a30 a31 a32 a33 a34 a35 a36 a37 a38 a39 a40 a41 a42 a43 a44 a45 a46 a47 a48 a49 a50 a51 a52 a53 a54 a55 a56 a57 a58 a59 =
  a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24 + a25 + a26 + a27 + a28 + a29 + a30 + a31 + a32 + a33 + a34 + a35 + a36 + a37 + a38 + a39 + a40 + a41 + a42 + a43 + a44 + a45 + a46 + a47 + a48 + a49 + a50 + a51 + a52 + a53 + a54 + a55 + a56 + a57 + a58 + a59

-- | A function with more arguments than the pre-generated (@ARG_PPPPPPPP -> 8@) ones
-- have
--
-- This results in a @ARG_GEN@ function (the number of arguments still fits in a
-- small bitmap).
{-# NOINLINE argGenFun #-}
argGenFun ::
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word ->
  Word
argGenFun a1 a2 a3 a4 a5 a6 a7 a8 a9 = a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9
