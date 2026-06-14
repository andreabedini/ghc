# Platform Abstraction Plan for GHC

*Status: design proposal / RFC. Goal: replace ad-hoc `#ifdef`-style conditional
compilation in the compiler and core libraries with a small set of typed
platform-abstraction interfaces, so that platform-dependent behaviour is
**delegated to a dedicated layer** instead of being scattered inline.*

This document is about API design and a migration plan. It deliberately says
little about autoconf/Hadrian: the build system only needs to *select* an
implementation at one or two well-defined points, and that selection mechanism
is a swappable detail of the design below.

---

## 1. The key reframe: there are two "platforms", and one is already done

Almost every discussion of "GHC and platforms" conflates two distinct things:

- **The target platform** — what GHC *compiles code for*.
- **The host platform** — what the `ghc` executable *itself runs on*.

These are independent (that independence *is* cross-compilation), and they need
**different** abstraction strategies because they have different variability:

| | Varies at… | Right abstraction shape |
|---|---|---|
| **Target** | **run time** (one GHC binary, many targets) | a **runtime value** (already exists: `GHC.Platform.Platform`) |
| **Host** | **build time** (a GHC binary runs on exactly one OS) | a **confined, typed interface** selected once |

The target platform is *already abstracted*. `compiler/GHC/Platform.hs` defines a
`Platform` record (arch/OS, word size, byte order, tables-next-to-code, leading
underscore, ELF/Mach-O-ness, constants, …) that is threaded through the compiler
as a plain value. This is why the code generators don't `#ifdef` on the target.
**We should not redo this work; we should extend it where target gaps remain and
copy its philosophy for the host.**

The actual mess is therefore concentrated in:

1. **Host-OS behaviour** in the compiler (file/process/signal/terminal handling).
2. **Build/feature configuration** (was-this-GHC-built-with-X) masquerading as platform code.
3. **Per-target conditional code inside the libraries** (`base`, `ghc-internal`),
   where "host" of the *compiled library* legitimately means "the target".

A census of the current tree bears this out (`.hs`/`.hsc`, compiler + core libs):

| Macro (by frequency) | Count | Real category |
|---|---:|---|
| `mingw32_HOST_OS` | 144 | Host OS (compiler) / target OS (libs) |
| `javascript_HOST_ARCH`, `wasm32_HOST_ARCH` | 67 | Target arch (mostly in libs) |
| `HAVE_INTERNAL_INTERPRETER`, `CAN_LOAD_DLL` | 41 | **Build/feature config, not platform** |
| `DEBUG` | 24 | **Build mode, not platform** |
| `WORDS_BIGENDIAN`, `WORD_SIZE_IN_BITS`, `TABLES_NEXT_TO_CODE` | ~30 | Host/target machine model |
| `HAVE_*` (eventfd, kqueue, epoll, signal.h, libzstd, …) | ~40 | Feature/capability detection |
| `MIN_VERSION_*`, `__GLASGOW_HASKELL__` | several | **Bootstrap compatibility — leave alone** |

So a successful transition is *first* a classification exercise and only *then* an
API exercise. The biggest single win is the ~14 compiler files that branch on
`mingw32_HOST_OS`.

---

## 2. What is in scope (and what is not)

**In scope — to be abstracted away:**

- Host-OS-dependent runtime behaviour in `compiler/` (process IDs, `stat`, temp
  files, signals, terminal/TTY detection, DLL loading, path quirks).
- Host machine-model assumptions in `compiler/` (host word size used for bit
  packing, e.g. uniques).
- Build/feature configuration currently expressed as CPP
  (`HAVE_INTERNAL_INTERPRETER`, `CAN_LOAD_DLL`, optional libs) — moved to a
  runtime configuration record, *not* a platform record.
- Per-target conditional code in `base`/`ghc-internal`, by extending the existing
  per-OS module hierarchy rather than inlining `#if`.

**Explicitly out of scope (keep CPP — it is the right tool there):**

- **Bootstrap/version shims** (`MIN_VERSION_*`, `__GLASGOW_HASKELL__`): these
  exist to compile GHC with a *range of* bootstrap compilers. That is genuine
  compile-time variability with no runtime meaning. Abstracting it buys nothing.
- **`DEBUG` / assertions**: build-mode, already largely funnelled through
  `GHC.Utils.Constants.debugIsOn` and `assert`. Finish that funnelling; don't
  invent a "platform" for it.
- **The RTS and other C code** (`rts/`, cbits): different language, different
  mechanism. Addressed separately in §7 — the C layer already uses a good
  directory-based abstraction we should lean into, not a Haskell API.

---

## 3. Design principles

1. **Delegate, don't branch.** Ordinary compiler code should never see a
   platform `#if`. It calls a typed operation; the *answer* to "which OS" lives
   in exactly one place.
2. **Model the host like the target: as a value.** GHC already threads a
   `Platform` value for the target. We introduce a `Host` value for the host.
   This makes the codebase uniform and, as a bonus, **testable** (you can inject
   a fake host).
3. **Separate "what platform" from "how GHC was built".** Feature flags
   (interpreter present? can dlopen? libzstd linked?) are *configuration*, not
   platform identity. They belong in the existing settings/config plumbing.
4. **Confine, then convert.** Step one is to push every conditional behind a
   stable interface module *without changing behaviour*. Only afterwards do we
   refine the interface. Confinement alone already removes `#if` from the bulk of
   the code and makes the rest reviewable.
5. **Make it stick with a lint.** Once an area is clean, a CI linter forbids new
   `#if defined(..._HOST_OS)` / `..._HOST_ARCH` outside the abstraction layer.
   Without this the mess regrows.

---

## 4. The API design

Three layers, matching the three real categories.

### 4.1 Target platform — extend the existing `Platform` (low effort)

Keep `GHC.Platform.Platform` as the single source of truth for target facts.
Where the compiler still CPP-branches on a *target* property, add a field/query
to `Platform` (or `PlatformMisc`) and replace the `#if` with a function of the
`Platform` value. There is little of this left in the compiler; treat it as
cleanup that rides along with the host work.

### 4.2 Host platform — a new `GHC.Platform.Host` abstraction (the core of the work)

Model the host exactly like the target: a value carrying both *identity* and a
record of *operations*.

```haskell
-- compiler/GHC/Platform/Host.hs  (interface; no CPP here)
module GHC.Platform.Host
  ( Host(..)
  , HostOps(..)
  , theHost          -- the single, real host for this build
  ) where

import GHC.Platform.ArchOS (ArchOS)

-- | Identity of the machine GHC is running on.
data Host = Host
  { hostArchOS    :: !ArchOS          -- reuse the target's ArchOS type
  , hostWordSize  :: !HostWordSize    -- host word size (bit-packing, uniques)
  , hostOps       :: !HostOps         -- the operations below
  }

-- | The OS-dependent operations the *compiler process* needs from its host.
--   Every member here corresponds to today's host `#ifdef` sites.
data HostOps = HostOps
  { hostGetProcessID   :: IO Int
      -- ^ was: _getpid vs Posix c_getpid  (Utils/TmpFs.hs)
  , hostFileInfo       :: FilePath -> IO FileInfo
      -- ^ mod-time/owner/group/mode; zeros on Windows  (SysTools/Ar.hs)
  , hostWithSignals    :: forall a. IO a -> IO a
      -- ^ install SIGINT/SIGTERM handlers, or id where unavailable  (Utils/Panic.hs)
  , hostStderrSupportsColor :: IO Bool
      -- ^ ANSI vs console API  (SysTools/Terminal.hs)
  , hostCanLoadDLL     :: Bool
      -- ^ note: this is really *config*; see 4.3 — listed to show the seam
  , ...
  }
```

Construction (`theHost`) is the **only** place that is OS-specific, and even that
is implemented by selecting an implementation module, not by inline branching:

```haskell
-- compiler/GHC/Platform/Host/Posix.hs    -- one implementation
-- compiler/GHC/Platform/Host/Windows.hs  -- another
-- compiler/GHC/Platform/Host.hs          -- picks one, see §4.4
hostOpsImpl :: HostOps   -- defined once per OS module
```

Why a record of operations rather than a typeclass:

- It is a *value*, like `Platform`; it threads and stores identically and can be
  put inside existing env/session records.
- No new type parameters ripple through the compiler's monads.
- Trivially mockable in tests (construct a `HostOps` with stubbed actions).
- Matches GHC's existing "dictionary-as-record" idiom (`Logger`, `TmpFs`,
  `Hooks`, `FinderCache` are all passed as values today).

A typeclass/Backpack signature is the "purer" alternative; see §4.4 for why it is
not the recommended first move.

#### Host word size

`WORD_SIZE_IN_BITS` in the compiler (e.g. unique bit-packing in
`GHC.Types.Unique`) is a *host* machine-model fact. Put it on `Host`
(`hostWordSize`) and, since these are hot paths, expose it as a compile-time
known constant in the single host module so the optimiser still sees a literal —
but the call sites read `hostWordSize`/a helper, not a macro.

### 4.3 Build & feature configuration — a `Config`/`Settings` record, NOT a platform

This is the most important *classification* call in the whole plan. Things like:

- `HAVE_INTERNAL_INTERPRETER` — was a bytecode interpreter linked into this GHC?
- `CAN_LOAD_DLL` — can this GHC `dlopen` object/shared code?
- `HAVE_LIBZSTD` — was zstd linked for info-table compression?

…are **not** properties of an OS. They are decisions made when *this particular
GHC* was built. Conflating them with "platform" is part of why the current code
is confusing. They belong in GHC's existing configuration plumbing
(`GHC.Settings`, `DynFlags`, the interpreter handle), expressed as ordinary
fields:

- `HAVE_INTERNAL_INTERPRETER`: already half-modelled by `Interp`’s
  `InternalInterp`/`ExternalInterp`. Finish it: make "internal interpreter
  available" a runtime field, drop the `#if` around the `InternalInterp` arms,
  and have the (single) builder of the interpreter decide availability. This also
  unlocks a long-standing wish: a GHC that can use an internal interpreter when
  present and fall back gracefully without recompilation.
- `CAN_LOAD_DLL`, `HAVE_LIBZSTD`: boolean (or `Maybe handle`) fields in settings,
  set once at startup.

The payoff: these stop being compile-time and become inspectable runtime state,
which is both cleaner and more flexible.

### 4.4 The selection mechanism (one small, swappable decision)

How is `theHost` / `hostOpsImpl` chosen per OS? Options, in order of
recommendation:

1. **One re-export module guarded by a single CPP** (pragmatic baseline):
   `GHC.Platform.Host` does
   `#if defined(mingw32_HOST_OS) import …Windows as Impl #else import …Posix as Impl #endif`.
   This reduces ~150 scattered `#if`s to **one**. Minimal risk, no build-system
   change, matches current idiom. Recommended for the first pass.

2. **Build-system module selection** (cleanest end state): the `.cabal`/Hadrian
   chooses `GHC.Platform.Host.Posix` vs `.Windows` as the module providing
   `hostOpsImpl` (mirrors how `rts/posix` vs `rts/win32` are selected, see §7).
   Zero CPP. You said not to dwell on the build system — note only that the *API*
   above is identical either way, so we can start with option 1 and migrate the
   single seam to option 2 later for free.

3. **Backpack signature** (`GHC.Platform.Host.Sig` with per-OS implementations):
   the most principled, and GHC supports Backpack — but the `ghc` library is not
   currently a Backpack unit, signatures complicate bootstrapping and slow
   builds, and tooling/IDE support is weaker. **Not recommended as the first
   move**; revisit once the record interface has proven the seam.

The crucial point: **all three share the exact same `Host`/`HostOps` API**. The
valuable, durable deliverable is the interface; the selector is interchangeable.

---

## 5. Worked examples (before → after)

**Process ID (`GHC/Utils/TmpFs.hs`):**

```haskell
-- before
#if defined(mingw32_HOST_OS)
foreign import ccall unsafe "_getpid" getProcessID :: IO Int
#else
getProcessID = fromIntegral <$> System.Posix.Internals.c_getpid
#endif

-- after (call site)
pid <- hostGetProcessID (hostOps host)   -- no CPP; impl lives in Host/{Posix,Windows}
```

**Archive file metadata (`GHC/SysTools/Ar.hs`):** `fileInfo` returns
`(0,0,0,0)` on Windows and `stat` results on POSIX → becomes `hostFileInfo`.

**Signal handlers (`GHC/Utils/Panic.hs`):** the three-way split
(POSIX signals / Windows console handler / none on wasm-wasi) collapses to
`hostWithSignals`, with the "none" case being `id` in the relevant impl. Note
`HAVE_SIGNAL_H` here is a *host capability*, correctly modelled as a host op, not
a separate feature flag.

**Terminal colour (`GHC/SysTools/Terminal.hs`):** ANSI vs Win32 console →
`hostStderrSupportsColor`.

**Internal interpreter (`GHC/Runtime/Interpreter.hs`):** the `#if
HAVE_INTERNAL_INTERPRETER` arms become unconditional code gated by a runtime
"internal interpreter available" field (§4.3).

---

## 6. Libraries (`base`, `ghc-internal`)

Here `mingw32_HOST_OS` / `*_HOST_ARCH` genuinely means **the target the library
is being compiled for** — the library is rebuilt per target, so it *is* a
compile-time constant. A runtime value would be wrong. The right abstraction is
the one `ghc-internal` already started: **per-OS module hierarchies**
(`GHC/Internal/System/Posix`, `GHC/Internal/IO/Windows`,
`GHC/Internal/Event/Windows`, …) selected by the build, with a thin
OS-independent façade module on top.

Plan for the libraries:

1. Inventory the remaining inline `#if` sites (heaviest: the event manager,
   `IO/Handle`, `System.CPUTime`, `Foreign.C` type aliases).
2. For each, move the OS bodies into the existing `.../Posix` / `.../Windows`
   submodule and leave the public module as a façade that re-exports the selected
   implementation.
3. Type-alias CPP (`HTYPE_*`, `CHARBUF_UTF16`) is generated from `configure`
   probes; keep it, but concentrate it in one `…/CTypes`-style module rather than
   re-deriving it at each use.

This is lower priority than the compiler work and can proceed independently.

---

## 7. The RTS and other C code

Out of the main scope, but worth stating the strategy so it isn't reinvented:
the RTS **already has the right abstraction** — a directory-per-OS split
(`rts/posix/`, `rts/win32/`, `rts/wasm/`) providing a common internal header API
(`OSMem`, `OSThreads`, `GetTime`, `Signals`, `Ticker`, …) selected by the build.
The C-side task is therefore *not* to invent an API but to:

- push the remaining inline `#if defined(mingw32_HOST_OS)` bodies in shared `.c`
  files down into the per-OS directories behind the existing headers, and
- treat the per-OS header set as the canonical "platform interface" for C,
  analogous to `HostOps` on the Haskell side.

No new mechanism; just finish applying the one that exists.

---

## 8. Migration plan (phased, each phase shippable)

**Phase 0 — Classification & guardrails (1 short pass).**
Tag every `#if` in `compiler/` and core libs as one of: target / host-OS /
host-machine-model / build-feature / bootstrap-version / debug. Produce the list
(the §1 census is the starting point). Add a CI linter (alongside the existing
`linters/`) that *reports* host-OS/arch CPP outside an allowlisted set of files —
initially warn-only.

**Phase 1 — Stand up the host abstraction, no behaviour change.**
Add `GHC.Platform.Host` (`Host`, `HostOps`) plus `Host/Posix` and `Host/Windows`
implementations populated by *moving* today's branches verbatim. Construct
`theHost` and make it reachable (top-level CAF to start; thread it into the
relevant env records as a follow-up). Ship: no functional change, but the
interface exists.

**Phase 2 — Convert compiler host sites.**
File by file (TmpFs, Ar, Panic, Terminal, Process, BaseDir, Driver/Session,
Runtime/Interpreter/Wasm, …) replace inline `#if` with `hostOps` calls. Each file
is an independent, reviewable MR. After each, tighten the linter to forbid host
CPP in that file. Convert host word-size sites (uniques) similarly.

**Phase 3 — Extract build/feature config (§4.3).**
Move `HAVE_INTERNAL_INTERPRETER`, `CAN_LOAD_DLL`, `HAVE_LIBZSTD`, etc. out of CPP
into settings/interp runtime fields. This is partly independent of the host work
and can run in parallel.

**Phase 4 — Close target-platform gaps.**
Eliminate any residual *target* `#if` in the compiler by adding `Platform`
fields/queries. Should be small.

**Phase 5 — Libraries.**
Apply §6 to `ghc-internal`/`base`, module-hierarchy by module-hierarchy.

**Phase 6 — Lock it in.**
Linter goes from warn to error for host-OS/arch CPP outside the abstraction
layer. Optionally migrate the single host selector from CPP (option 4.4.1) to
build-system module selection (4.4.2) or Backpack (4.4.3).

**Phase 7 (optional, C side).**
Finish pushing RTS inline `#if`s into the per-OS directories (§7).

Phases 1–2 deliver the great majority of the user-visible cleanup and are the
right place to concentrate effort.

---

## 9. Testing & risk

- **Behaviour preservation:** Phases 1–2 are pure refactors. The `HostOps`
  record makes them *more* testable than before — add unit tests that exercise
  the abstraction with a stub `HostOps`, impossible with CPP today.
- **Cross-compilation safety:** keep the host/target distinction rigid. A review
  smell to watch for: any host op that ends up *depending on the target* (or vice
  versa) signals a miscategorised site.
- **Performance:** hot host-machine-model facts (word size) must stay
  constant-folded; keep them as compile-time-known values in the single host
  module and check Core if in doubt.
- **Bootstrap range:** do **not** touch `MIN_VERSION_*`/`__GLASGOW_HASKELL__`
  CPP; the abstraction must compile across the supported bootstrap window, so the
  interface modules themselves should be conservative Haskell.
- **Regression of the mess:** the linter is load-bearing. Without enforced
  confinement, new `#if`s reappear; with it, the clean areas stay clean.

---

## 10. Summary

- GHC already solved the *target* platform problem with the `Platform` value;
  reuse that philosophy, don't reinvent it.
- The remaining `#ifdef` pain is mostly **host-OS** behaviour in the compiler
  plus **build-feature flags** misfiled as platform code.
- Introduce a `Host`/`HostOps` **value** (mirroring `Platform`) so ordinary code
  *delegates* instead of branching; move feature flags into runtime config;
  extend the libraries' existing per-OS module split.
- Migrate in small, behaviour-preserving phases, and enforce the result with a
  CI linter that bans new platform CPP outside the abstraction layer.
- The durable deliverable is the `Host`/`HostOps` interface; the per-OS selector
  (single CPP → build selection → Backpack) is an interchangeable detail.
