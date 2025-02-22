{-# LANGUAGE Unsafe #-}
{-# LANGUAGE NoImplicitPrelude
           , BangPatterns
           , RankNTypes
           , MagicHash
           , ScopedTypeVariables
           , UnboxedTuples
  #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
{-# OPTIONS_HADDOCK not-home #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.Internal.IO
-- Copyright   :  (c) The University of Glasgow 1994-2023
-- License     :  see libraries/base/LICENSE
--
-- Maintainer  :  ghc-devs@haskell.org
-- Stability   :  internal
-- Portability :  non-portable (GHC Extensions)
--
-- Definitions for the 'IO' monad and its friends.
--
-- /The API of this module is unstable and not meant to be consumed by the general public./
-- If you absolutely must depend on it, make sure to use a tight upper
-- bound, e.g., @base < 4.X@ rather than @base < 5@, because the interface can
-- change rapidly without much warning.
--
-----------------------------------------------------------------------------

module GHC.Internal.IO (
        IO(..), unIO, liftIO, mplusIO,
        unsafePerformIO, unsafeInterleaveIO,
        unsafeDupablePerformIO, unsafeDupableInterleaveIO,
        noDuplicate,
        annotateIO,

        -- To and from ST
        stToIO, ioToST, unsafeIOToST, unsafeSTToIO,

        FilePath,

        catch, catchNoPropagate, catchException, catchExceptionNoPropagate, catchAny, throwIO,
        rethrowIO,
        mask, mask_, uninterruptibleMask, uninterruptibleMask_,
        MaskingState(..), getMaskingState,
        unsafeUnmask, interruptible,
        onException, bracket, finally, evaluate, seq#,
        mkUserError
    ) where

import GHC.Internal.Base
import GHC.Internal.ST
import GHC.Internal.Exception
import GHC.Internal.Exception.Type (NoBacktrace(..), WhileHandling(..), HasExceptionContext, ExceptionWithContext(..))
import GHC.Internal.Show
import GHC.Internal.IO.Unsafe
import GHC.Internal.Unsafe.Coerce ( unsafeCoerce )

import GHC.Internal.Exception.Context ( ExceptionAnnotation )
import GHC.Internal.Stack.Types ( HasCallStack )
import {-# SOURCE #-} GHC.Internal.Stack ( withFrozenCallStack )
import {-# SOURCE #-} GHC.Internal.IO.Exception ( userError, IOError )

-- ---------------------------------------------------------------------------
-- The IO Monad

{-
The IO Monad is just an instance of the ST monad, where the state thread
is the real world.  We use the exception mechanism (in GHC.Exception) to
implement IO exceptions.

NOTE: The IO representation is deeply wired in to various parts of the
system.  The following list may or may not be exhaustive:

Compiler  - types of various primitives in GHC.Builtin.PrimOps

RTS       - forceIO (StgStartup.cmm)
          - catchzh_fast, (un)?blockAsyncExceptionszh_fast, raisezh_fast
            (Exception.cmm)
          - raiseAsync (RaiseAsync.c)

Prelude   - GHC.Internal.IO.hs, and several other places including
            GHC.Internal.Exception.hs.

Libraries - parts of hslibs/lang.

--SDM
-}

liftIO :: IO a -> State# RealWorld -> STret RealWorld a
liftIO (IO m) = \s -> case m s of (# s', r #) -> STret s' r

-- ---------------------------------------------------------------------------
-- Coercions between IO and ST

-- | Embed a strict state thread in an 'IO'
-- action.  The 'RealWorld' parameter indicates that the internal state
-- used by the 'ST' computation is a special one supplied by the 'IO'
-- monad, and thus distinct from those used by invocations of 'runST'.
stToIO        :: ST RealWorld a -> IO a
stToIO (ST m) = IO m

-- | Convert an 'IO' action into an 'ST' action. The type of the result
-- is constrained to use a 'RealWorld' state thread, and therefore the
-- result cannot be passed to 'runST'.
ioToST        :: IO a -> ST RealWorld a
ioToST (IO m) = (ST m)

-- | Convert an 'IO' action to an 'ST' action.
-- This relies on 'IO' and 'ST' having the same representation modulo the
-- constraint on the state thread type parameter.
unsafeIOToST        :: IO a -> ST s a
unsafeIOToST (IO io) = ST $ \ s -> (unsafeCoerce io) s

-- | Convert an 'ST' action to an 'IO' action.
-- This relies on 'IO' and 'ST' having the same representation modulo the
-- constraint on the state thread type parameter.
--
-- For an example demonstrating why this is unsafe, see
-- https://mail.haskell.org/pipermail/haskell-cafe/2009-April/060719.html
unsafeSTToIO :: ST s a -> IO a
unsafeSTToIO (ST m) = IO (unsafeCoerce m)

-- -----------------------------------------------------------------------------
-- | File and directory names are values of type 'String', whose precise
-- meaning is operating system dependent. Files can be opened, yielding a
-- handle which can then be used to operate on the contents of that file.

type FilePath = String

-- -----------------------------------------------------------------------------
-- Primitive catch and throwIO

{-
catchException/catch used to handle the passing around of the state to the
action and the handler.  This turned out to be a bad idea - it meant
that we had to wrap both arguments in thunks so they could be entered
as normal (remember IO returns an unboxed pair...).

Now catch# has type

    catch# :: IO a -> (b -> IO a) -> IO a

(well almost; the compiler doesn't know about the IO newtype so we
have to work around that in the definition of catch below).
-}

-- | Catch an exception in the 'IO' monad.
--
-- Note that this function is /strict/ in the action. That is,
-- @catchException undefined b == _|_@. See #exceptions_and_strictness#
-- for details.
catchException :: Exception e => IO a -> (e -> IO a) -> IO a
catchException !io handler = catch io handler

-- | A variant of 'catchException' which does not annotate the handler with 'WhileHandling'
catchExceptionNoPropagate :: Exception e => IO a -> (ExceptionWithContext e -> IO a) -> IO a
catchExceptionNoPropagate !io handler = catchNoPropagate io handler

-- | This is the simplest of the exception-catching functions.  It
-- takes a single argument, runs it, and if an exception is raised
-- the \"handler\" is executed, with the value of the exception passed as an
-- argument.  Otherwise, the result is returned as normal.  For example:
--
-- >   catch (readFile f)
-- >         (\e -> do let err = show (e :: IOException)
-- >                   hPutStr stderr ("Warning: Couldn't open " ++ f ++ ": " ++ err)
-- >                   return "")
--
-- Note that we have to give a type signature to @e@, or the program
-- will not typecheck as the type is ambiguous. While it is possible
-- to catch exceptions of any type, see the section \"Catching all
-- exceptions\" (in "Control.Exception") for an explanation of the problems with doing so.
--
-- For catching exceptions in pure (non-'IO') expressions, see the
-- function 'evaluate'.
--
-- Note that due to Haskell\'s unspecified evaluation order, an
-- expression may throw one of several possible exceptions: consider
-- the expression @(error \"urk\") + (1 \`div\` 0)@.  Does
-- the expression throw
-- @ErrorCall \"urk\"@, or @DivideByZero@?
--
-- The answer is \"it might throw either\"; the choice is
-- non-deterministic. If you are catching any type of exception then you
-- might catch either. If you are calling @catch@ with type
-- @IO Int -> (ArithException -> IO Int) -> IO Int@ then the handler may
-- get run with @DivideByZero@ as an argument, or an @ErrorCall \"urk\"@
-- exception may be propagated further up. If you call it again, you
-- might get the opposite behaviour. This is ok, because 'catch' is an
-- 'IO' computation.
--
catch   :: Exception e
        => IO a         -- ^ The computation to run
        -> (e -> IO a)  -- ^ Handler to invoke if an exception is raised
        -> IO a
-- See #exceptions_and_strictness#.
catch (IO io) handler = IO $ catch# io handler'
  where
    handler' e =
      case fromException e of
        Just e' -> unIO (annotateIO (WhileHandling e) (handler e'))
        Nothing -> raiseIO# e

-- | A variant of 'catch' which doesn't annotate the handler with the exception
-- which was caught. This function should be used when you are implementing your own
-- error handling functions which may rethrow the exceptions.
--
-- In the case where you rethrow an exception without modifying it, you should
-- rethrow the exception with the old exception context.
catchNoPropagate :: Exception e
                 => IO a
                 -> (ExceptionWithContext e -> IO a)
                 -> IO a
catchNoPropagate (IO io) handler = IO $ catch# io handler'
  where
    handler' e =
      case fromException e of
        Just e' -> unIO (handler e')
        Nothing -> raiseIO# e

-- | Catch any 'Exception' type in the 'IO' monad.
--
-- Note that this function is /strict/ in the action. That is,
-- @catchAny undefined b == _|_@. See #exceptions_and_strictness# for
-- details.
--
-- If you rethrow an exception, you should reuse the supplied ExceptionContext.
catchAny :: IO a -> (forall e . (HasExceptionContext, Exception e) => e -> IO a) -> IO a
catchAny !(IO io) handler = IO $ catch# io handler'
  where
    handler' se@(SomeException e) = unIO (annotateIO (WhileHandling se) (handler e))

-- | Execute an 'IO' action, adding the given 'ExceptionContext'
-- to any thrown synchronous exceptions.
--
-- @since base-4.20.0.0
annotateIO :: forall e a. ExceptionAnnotation e => e -> IO a -> IO a
annotateIO ann (IO io) = IO (catch# io handler)
  where
    handler se = raiseIO# (addExceptionContext ann se)

-- Using catchException here means that if `m` throws an
-- 'IOError' /as an imprecise exception/, we will not catch
-- it. No one should really be doing that anyway.
mplusIO :: IO a -> IO a -> IO a
mplusIO m n = m `catchException` \ (_ :: IOError) -> n

-- | A variant of 'throw' that can only be used within the 'IO' monad.
--
-- Although 'throwIO' has a type that is an instance of the type of 'throw', the
-- two functions are subtly different:
--
-- > throw e   `seq` ()  ===> throw e
-- > throwIO e `seq` ()  ===> ()
--
-- The first example will cause the exception @e@ to be raised,
-- whereas the second one won\'t.  In fact, 'throwIO' will only cause
-- an exception to be raised when it is used within the 'IO' monad.
--
-- The 'throwIO' variant should be used in preference to 'throw' to
-- raise an exception within the 'IO' monad because it guarantees
-- ordering with respect to other operations, whereas 'throw'
-- does not. We say that 'throwIO' throws *precise* exceptions and
-- 'throw', 'error', etc. all throw *imprecise* exceptions.
-- For example
--
-- > throw e + error "boom" ===> error "boom"
-- > throw e + error "boom" ===> throw e
--
-- are both valid reductions and the compiler may pick any (loop, even), whereas
--
-- > throwIO e >> error "boom" ===> throwIO e
--
-- will always throw @e@ when executed.
--
-- See also the
-- [GHC wiki page on precise exceptions](https://gitlab.haskell.org/ghc/ghc/-/wikis/exceptions/precise-exceptions)
-- for a more technical introduction to how GHC optimises around precise vs.
-- imprecise exceptions.
--
throwIO :: (HasCallStack, Exception e) => e -> IO a
throwIO e = withFrozenCallStack $ do
    se <- toExceptionWithBacktrace e
    IO (raiseIO# se)

-- | A utility to use when rethrowing exceptions, no new backtrace will be attached
-- when rethrowing an exception but you must supply the existing context.
rethrowIO :: Exception e => ExceptionWithContext e -> IO a
rethrowIO e = throwIO (NoBacktrace e)

-- -----------------------------------------------------------------------------
-- Controlling asynchronous exception delivery

-- Applying 'block' to a computation will
-- execute that computation with asynchronous exceptions
-- /blocked/.  That is, any thread which
-- attempts to raise an exception in the current thread with 'GHC.Internal.Control.Exception.throwTo' will be
-- blocked until asynchronous exceptions are unblocked again.  There\'s
-- no need to worry about re-enabling asynchronous exceptions; that is
-- done automatically on exiting the scope of
-- 'block'.
--
-- Threads created by 'Control.Concurrent.forkIO' inherit the blocked
-- state from the parent; that is, to start a thread in blocked mode,
-- use @block $ forkIO ...@.  This is particularly useful if you need to
-- establish an exception handler in the forked thread before any
-- asynchronous exceptions are received.
block :: IO a -> IO a
block (IO io) = IO $ maskAsyncExceptions# io

-- To re-enable asynchronous exceptions inside the scope of
-- 'block', 'unblock' can be
-- used.  It scopes in exactly the same way, so on exit from
-- 'unblock' asynchronous exception delivery will
-- be disabled again.
unblock :: IO a -> IO a
unblock = unsafeUnmask

unsafeUnmask :: IO a -> IO a
unsafeUnmask (IO io) = IO $ unmaskAsyncExceptions# io

-- | Allow asynchronous exceptions to be raised even inside 'mask', making
-- the operation interruptible (see the discussion of "Interruptible operations"
-- in 'Control.Exception').
--
-- When called outside 'mask', or inside 'uninterruptibleMask', this
-- function has no effect.
--
-- @since base-4.9.0.0
interruptible :: IO a -> IO a
interruptible act = do
  st <- getMaskingState
  case st of
    Unmasked              -> act
    MaskedInterruptible   -> unsafeUnmask act
    MaskedUninterruptible -> act

blockUninterruptible :: IO a -> IO a
blockUninterruptible (IO io) = IO $ maskUninterruptible# io

-- | Describes the behaviour of a thread when an asynchronous
-- exception is received.
data MaskingState
  = Unmasked -- ^ asynchronous exceptions are unmasked (the normal state)
  | MaskedInterruptible
      -- ^ the state during 'mask': asynchronous exceptions are masked, but blocking operations may still be interrupted
  | MaskedUninterruptible
      -- ^ the state during 'uninterruptibleMask': asynchronous exceptions are masked, and blocking operations may not be interrupted
 deriving ( Eq   -- ^ @since base-4.3.0.0
          , Show -- ^ @since base-4.3.0.0
          )

-- | Returns the 'MaskingState' for the current thread.
getMaskingState :: IO MaskingState
getMaskingState  = IO $ \s ->
  case getMaskingState# s of
     (# s', i #) -> (# s', case i of
                             0# -> Unmasked
                             1# -> MaskedUninterruptible
                             _  -> MaskedInterruptible #)

onException :: IO a -> IO b -> IO a
onException io what = io `catchExceptionNoPropagate` \e -> do
    _ <- what
    rethrowIO (e :: ExceptionWithContext SomeException)

-- | Executes an IO computation with asynchronous
-- exceptions /masked/.  That is, any thread which attempts to raise
-- an exception in the current thread with 'GHC.Internal.Control.Exception.throwTo'
-- will be blocked until asynchronous exceptions are unmasked again.
--
-- The argument passed to 'mask' is a function that takes as its
-- argument another function, which can be used to restore the
-- prevailing masking state within the context of the masked
-- computation.  For example, a common way to use 'mask' is to protect
-- the acquisition of a resource:
--
-- > mask $ \restore -> do
-- >     x <- acquire
-- >     restore (do_something_with x) `onException` release
-- >     release
--
-- This code guarantees that @acquire@ is paired with @release@, by masking
-- asynchronous exceptions for the critical parts. (Rather than write
-- this code yourself, it would be better to use
-- 'GHC.Internal.Control.Exception.bracket' which abstracts the general pattern).
--
-- Note that the @restore@ action passed to the argument to 'mask'
-- does not necessarily unmask asynchronous exceptions, it just
-- restores the masking state to that of the enclosing context.  Thus
-- if asynchronous exceptions are already masked, 'mask' cannot be used
-- to unmask exceptions again.  This is so that if you call a library function
-- with exceptions masked, you can be sure that the library call will not be
-- able to unmask exceptions again.  If you are writing library code and need
-- to use asynchronous exceptions, the only way is to create a new thread;
-- see 'Control.Concurrent.forkIOWithUnmask'.
--
-- Asynchronous exceptions may still be received while in the masked
-- state if the masked thread /blocks/ in certain ways; see
-- "Control.Exception#interruptible".
--
-- Threads created by 'Control.Concurrent.forkIO' inherit the
-- 'MaskingState' from the parent; that is, to start a thread in the
-- 'MaskedInterruptible' state,
-- use @mask_ $ forkIO ...@.  This is particularly useful if you need
-- to establish an exception handler in the forked thread before any
-- asynchronous exceptions are received.  To create a new thread in
-- an unmasked state use 'Control.Concurrent.forkIOWithUnmask'.
--
mask  :: ((forall a. IO a -> IO a) -> IO b) -> IO b

-- | Like 'mask', but does not pass a @restore@ action to the argument.
mask_ :: IO a -> IO a

-- | Like 'mask', but the masked computation is not interruptible (see
-- "Control.Exception#interruptible").  THIS SHOULD BE USED WITH
-- GREAT CARE, because if a thread executing in 'uninterruptibleMask'
-- blocks for any reason, then the thread (and possibly the program,
-- if this is the main thread) will be unresponsive and unkillable.
-- This function should only be necessary if you need to mask
-- exceptions around an interruptible operation, and you can guarantee
-- that the interruptible operation will only block for a short period
-- of time.
--
uninterruptibleMask :: ((forall a. IO a -> IO a) -> IO b) -> IO b

-- | Like 'uninterruptibleMask', but does not pass a @restore@ action
-- to the argument.
uninterruptibleMask_ :: IO a -> IO a

mask_ io = mask $ \_ -> io

mask io = do
  b <- getMaskingState
  case b of
    Unmasked              -> block $ io unblock
    MaskedInterruptible   -> io block
    MaskedUninterruptible -> io blockUninterruptible

uninterruptibleMask_ io = uninterruptibleMask $ \_ -> io

uninterruptibleMask io = do
  b <- getMaskingState
  case b of
    Unmasked              -> blockUninterruptible $ io unblock
    MaskedInterruptible   -> blockUninterruptible $ io block
    MaskedUninterruptible -> io blockUninterruptible

bracket
        :: IO a         -- ^ computation to run first (\"acquire resource\")
        -> (a -> IO b)  -- ^ computation to run last (\"release resource\")
        -> (a -> IO c)  -- ^ computation to run in-between
        -> IO c         -- returns the value from the in-between computation
bracket before after thing =
  mask $ \restore -> do
    a <- before
    r <- restore (thing a) `onException` after a
    _ <- after a
    return r

finally :: IO a         -- ^ computation to run first
        -> IO b         -- ^ computation to run afterward (even if an exception
                        -- was raised)
        -> IO a         -- returns the value from the first computation
a `finally` sequel =
  mask $ \restore -> do
    r <- restore a `onException` sequel
    _ <- sequel
    return r


-- | The primitive used to implement 'GHC.IO.evaluate'.
-- Prefer to use 'GHC.IO.evaluate' whenever possible!
seq# :: forall a s. a -> State# s -> (# State# s, a #)
-- See Note [seq# magic] in GHC.Types.Id.Make
{-# NOINLINE seq# #-}  -- seq# is inlined manually in CorePrep
seq# a s = let !a' = lazy a in (# s, a' #)

-- | Evaluate the argument to weak head normal form.
--
-- 'evaluate' is typically used to uncover any exceptions that a lazy value
-- may contain, and possibly handle them.
--
-- 'evaluate' only evaluates to /weak head normal form/. If deeper
-- evaluation is needed, the @force@ function from @Control.DeepSeq@
-- may be handy:
--
-- > evaluate $ force x
--
-- There is a subtle difference between @'evaluate' x@ and @'return' '$!' x@,
-- analogous to the difference between 'throwIO' and 'throw'. If the lazy
-- value @x@ throws an exception, @'return' '$!' x@ will fail to return an
-- 'IO' action and will throw an exception instead. @'evaluate' x@, on the
-- other hand, always produces an 'IO' action; that action will throw an
-- exception upon /execution/ iff @x@ throws an exception upon /evaluation/.
--
-- The practical implication of this difference is that due to the
-- /imprecise exceptions/ semantics,
--
-- > (return $! error "foo") >> error "bar"
--
-- may throw either @"foo"@ or @"bar"@, depending on the optimizations
-- performed by the compiler. On the other hand,
--
-- > evaluate (error "foo") >> error "bar"
--
-- is guaranteed to throw @"foo"@.
--
-- The rule of thumb is to use 'evaluate' to force or handle exceptions in
-- lazy values. If, on the other hand, you are forcing a lazy value for
-- efficiency reasons only and do not care about exceptions, you may
-- use @'return' '$!' x@.
evaluate :: a -> IO a
evaluate a = IO $ \s -> seq# a s -- NB. see #2273, #5129

{- $exceptions_and_strictness

Laziness can interact with @catch@-like operations in non-obvious ways (see,
e.g. GHC #11555 and #13330). For instance, consider these subtly-different
examples:

> test1 = GHC.Internal.Control.Exception.catch (error "uh oh") (\(_ :: SomeException) -> putStrLn "it failed")
>
> test2 = GHC.Internal.IO.catchException (error "uh oh") (\(_ :: SomeException) -> putStrLn "it failed")

While @test1@ will print "it failed", @test2@ will print "uh oh".

When using 'catchException', exceptions thrown while evaluating the
action-to-be-executed will not be caught; only exceptions thrown during
execution of the action will be handled by the exception handler.

Since this strictness is a small optimization and may lead to surprising
results, all of the @catch@ and @handle@ variants offered by "Control.Exception"
use 'catch' rather than 'catchException'.
-}

-- For SOURCE import by GHC.Internal.Base to define failIO.
mkUserError       :: [Char]  -> SomeException
mkUserError str   = toException (userError str)
