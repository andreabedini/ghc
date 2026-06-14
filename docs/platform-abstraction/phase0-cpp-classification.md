# Phase 0 — CPP classification & guardrails

*Companion to [`plan.md`](./plan.md). This is the deliverable for **Phase 0**:
classify every CPP conditional in the compiler and core libraries, and stand up
a (warn-only) linter that reports host-OS/arch CPP outside the future
abstraction layer. No behaviour changes; no API yet.*

The numbers below are a census of `#if` / `#ifdef` / `#ifndef` / `#elif`
conditionals in tracked `.hs`/`.hsc` files, reproducible with
`docs/platform-abstraction/census.py` (see end). They are the ground truth that
supersedes the rough estimates in `plan.md §1`.

---

## 1. Census by category (compiler + `base` + `ghc-internal`)

| Category | Occurrences | Files | Disposition |
|---|---:|---:|---|
| host/target **OS** (`*_HOST_OS`) | 170 | 46 | split: compiler = host (abstract); libs = target (module split) |
| host/target **ARCH** (`*_HOST_ARCH`) | 69 | 31 | same split as OS |
| **machine-model** (`WORD_SIZE_IN_BITS`, `WORDS_BIGENDIAN`, `TABLES_NEXT_TO_CODE`, …) | 57 | 22 | compiler host bits → `Host`; libs/target → `Platform` |
| **capability** (`HAVE_*`: eventfd, epoll, kqueue, signal.h, …) | 57 | 19 | host op (compiler) or feature config / target capability (libs) |
| **build-feature** (`HAVE_INTERNAL_INTERPRETER`, `CAN_LOAD_DLL`, `HAVE_LIBZSTD`) | 43 | 11 | **not platform** → runtime `Settings`/`Interp` (plan §4.3) |
| **debug** (`DEBUG`) | 28 | 12 | **leave** — funnel through `debugIsOn`/`assert` |
| **bootstrap-version** (`MIN_VERSION_*`, `__GLASGOW_HASKELL__`) | 17 | 9 | **leave** — genuine bootstrap-range variability |
| other | 124 | 34 | reclassify case-by-case (mostly capability/build flags) |

Top individual tokens: `mingw32_HOST_OS` (144), `javascript_HOST_ARCH` (58),
`WORD_SIZE_IN_BITS` (36), `HAVE_INTERNAL_INTERPRETER` (28), `DEBUG` (25),
`CAN_LOAD_DLL` (13), `WORDS_BIGENDIAN` (11), `CHARBUF_UTF16` (11).

The `mingw32_HOST_OS` (144) count matches `plan.md §1` exactly.

---

## 2. The key split: compiler = host, libraries = target

`*_HOST_OS`/`*_HOST_ARCH` mean **two different things** depending on where they
appear, and that determines the abstraction:

- **In `compiler/`** the macro describes the machine the `ghc` *executable* runs
  on → **host**. Varies at *build* time → abstract behind a typed `Host`/`HostOps`
  value (plan §4.2). **This is the linter's scope.**
- **In `libraries/` (`base`, `ghc-internal`)** the library is recompiled per
  target, so the macro is a per-target compile-time constant describing the
  **target** → keep, but migrate to per-OS module hierarchies (plan §6). **Out of
  the linter's scope** — a runtime value would be *wrong* here.

| | host-OS/arch CPP files | occurrences |
|---|---:|---:|
| `compiler/` (host — abstract) | **15** | 34 |
| `base` + `ghc-internal` (target — module split) | 53 | 205 |

---

## 3. Compiler host-CPP inventory (the 15 files — linter baseline)

Each is an independent, behaviour-preserving conversion target for Phase 2. The
"host op" column is the proposed `HostOps` member (plan §4.2) or other
disposition. As each file is converted it is removed from the linter allowlist
(`testsuite/tests/linters/regex-linters/check-host-cpp.py`).

Conversion status is tracked by the `check-host-cpp.py` allowlist; ✅ = converted
(removed from the allowlist). As of the latest Phase 2 commit, 11 of 15 remain.

| File | Branches on | What it decides | Disposition |
|---|---|---|---|
| ✅ `GHC/Utils/TmpFs.hs` | `mingw32` | `_getpid` vs POSIX `c_getpid` | `hostGetProcessID` (done) |
| ✅ `GHC/SysTools/Ar.hs` | `mingw32` | file mtime/owner/mode: zeros vs `stat` | `hostArchiveFileInfo` (done) |
| `GHC/Utils/Panic.hs` | `mingw32` | SIGINT/SIGTERM vs console-ctrl handler | `hostWithSignals` |
| `GHC/SysTools/Terminal.hs` | `mingw32` | ANSI vs Win32 console colour | `hostStderrSupportsColor` |
| ✅ `GHC/SysTools/Process.hs` | `mingw32` | `PATH` mangling for child env | `hostMangleGccPathEnv` (done) |
| `GHC/SysTools/BaseDir.hs` | `mingw32` | tooldir expansion / exe-relative libdir | host op for exe path + path quirks |
| `GHC/Runtime/Utils.hs` | `mingw32` | `_close` import + pipe/handle handling | host op or move to impl module |
| `GHC/Runtime/Interpreter/Wasm.hs` | `mingw32` | POSIX-only wasm interpreter pieces | host op / impl module (wasi has none) |
| `GHC/Linker/Loader.hs` | `mingw32`, `wasm32` | `getSystemDirectory`; DLL/load specifics | mix: host op + build-feature (`CAN_LOAD_DLL`, §4.3) |
| `GHC/Driver/Session.hs` | `linux`,`mingw32` | `-rdynamic`/`--export-all-symbols`; path split marker | target query on `Platform` + host path-sep op |
| `GHC/Driver/MakeAction.hs` | `wasm32` | wasm-specific make behaviour | host op / impl module |
| `GHC.hs` | `wasm32`, `mingw32` | wasm guard; `.\` path prefix check | host op for path quirks |
| ✅ `GHC/Utils/Touch.hs` | `mingw32` | touch implementation | `hostTouch` (done) |
| `GHC/Utils/Constants.hs` | `mingw32`, `darwin` | `isWindowsHost`/`isDarwinHost` constants | **already a host abstraction** — fold into `Host` identity |
| `GHC/Llvm/Types.hs` | `darwin` | `-fno-asm-shortcutting` OPTIONS pragma | special: file-level pragma; allowlist permanently or handle via build flag |

Notes:
- `GHC/Utils/Constants.hs` already exposes `isWindowsHost`/`isDarwinHost` as
  plain `Bool`s — a proto-`Host`. The clean end state moves these onto the `Host`
  identity record; until then they are the recommended call target instead of new
  inline `#if`s.
- `GHC/Llvm/Types.hs` is a top-level `{-# OPTIONS_GHC #-}` pragma, not runtime
  behaviour — it cannot become a `HostOps` call and stays allowlisted (or moves
  to a build-system flag) rather than being converted.
- `CAN_LOAD_DLL`/`HAVE_INTERNAL_INTERPRETER` appearing in `Loader.hs`/elsewhere
  are **build-feature**, handled in plan §4.3, *not* by the host linter.

---

## 4. What stays as CPP (explicitly not abstracted)

Confirmed by the census, matching `plan.md §2`:

- **bootstrap-version** (17 occ): `MIN_VERSION_*`, `__GLASGOW_HASKELL__` — needed
  to compile GHC across its supported bootstrap window. No runtime meaning.
- **debug** (28 occ): `DEBUG` — build mode; continue funnelling through
  `GHC.Utils.Constants.debugIsOn` / `assert`.
- **build-feature** (43 occ): `HAVE_INTERNAL_INTERPRETER`, `CAN_LOAD_DLL`,
  `HAVE_LIBZSTD` — configuration, moved to runtime `Settings`/`Interp` in plan
  §4.3, not to a platform record.
- **C code** (`rts/`, cbits): out of scope here; directory-per-OS strategy in
  plan §7.

---

## 5. Guardrail: the host-CPP linter

`testsuite/tests/linters/regex-linters/check-host-cpp.py` reports `*_HOST_OS` /
`*_HOST_ARCH` CPP conditionals in `compiler/` that are **not** in the abstraction
layer and **not** in the baseline allowlist (the 15 files above).

- **Phase 0 (now): warn-only.** `ENFORCE = False` — the linter prints findings to
  stdout but exits 0, so it never breaks CI. With the baseline allowlist, a clean
  tree produces no output today; it only reports *new* host CPP added to other
  compiler files.
- **Phase 2: ratchet.** As each file is converted, delete it from
  `ALLOWLIST`. The linter then guards that file against regressions.
- **Phase 6: enforce.** Flip `ENFORCE = True`; new/regressed host CPP outside the
  abstraction layer fails CI.

It is wired alongside the other regex linters (`make host-cpp` in
`testsuite/tests/linters/Makefile`, `host-cpp` test in `all.T`) and needs no GHC
build — it runs under plain `python3`.

---

## 6. Reproducing the census

`docs/platform-abstraction/census.py` regenerates §1–§3. Run from the repo root:

```
python3 docs/platform-abstraction/census.py
```
