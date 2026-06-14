#!/bin/bash
#
# SessionStart hook for Claude Code on the web.
#
# Bootstraps the boot toolchain this fork's build needs: a GHC 9.8.4 boot
# compiler (Makefile `GHC0`) and `cabal` (Makefile `CABAL0`), installed via
# ghcup and put on PATH for the session. With these present, `make stage1`
# (and the rest of the staged build) can run.
#
# NETWORK: this requires the environment's network policy to allow the GHC
# download hosts:
#   - get-ghcup.haskell.org   (the ghcup installer)
#   - downloads.haskell.org   (GHC + cabal bindists)
#   - hackage.haskell.org     (cabal package dependencies)
# These are set at environment-creation time. If they are blocked the toolchain
# install will fail; see docs/platform-abstraction/validate-build.sh for the
# same requirement. The boot libraries are vendored in libraries/, so
# gitlab.haskell.org is NOT needed.
#
# This hook only provisions the toolchain; it does not run the (long) staged
# build. Run `make stage1` yourself once the hook has completed.
#
# Idempotent and non-interactive: safe to re-run; installs are skipped when the
# requested versions are already present.

set -euo pipefail

# Web-only: on a local machine you manage your own toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

BOOT_GHC="9.8.4"
GHCUP_BIN="${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/bin"

# Make ghcup-installed tools available for the rest of this session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PATH="$HOME/.ghcup/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi
export PATH="$GHCUP_BIN:$PATH"

# 1. ghcup itself.
if ! command -v ghcup >/dev/null 2>&1; then
  export BOOTSTRAP_HASKELL_NONINTERACTIVE=1
  export BOOTSTRAP_HASKELL_MINIMAL=1   # we install ghc/cabal explicitly below
  curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
fi
# shellcheck disable=SC1090
source "${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/env"

# 2. Boot GHC (Makefile default GHC0=ghc-9.8.4).
if ! command -v "ghc-$BOOT_GHC" >/dev/null 2>&1; then
  ghcup install ghc "$BOOT_GHC"
fi
ghcup set ghc "$BOOT_GHC"

# 3. cabal (used to build the pinned cabal in stage0, and the build generally).
if ! command -v cabal >/dev/null 2>&1; then
  ghcup install cabal latest
  ghcup set cabal latest
fi
cabal update || true

echo "Boot toolchain ready: $(ghc-$BOOT_GHC --version 2>/dev/null), cabal $(cabal --version 2>/dev/null | head -1)"
echo "Run 'make stage1' to build the stage1 compiler."
