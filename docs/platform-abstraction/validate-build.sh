#!/usr/bin/env bash
#
# Validate the platform-abstraction work (docs/platform-abstraction/) by
# bootstrapping the toolchain and building the stage1 ghc, which compiles the
# new GHC.Platform.Host.* modules and every converted call site.
#
# REQUIREMENTS (network egress allowlist for this environment):
#   - gitlab.haskell.org    : boot-library submodules (libraries/*)
#   - downloads.haskell.org : ghcup + a boot GHC >= 9.10
#                             (apt's ghc 9.4.7 is too old: configure.ac sets
#                              MinBootGhcVersion=9.10 for this 9.15 tree)
#   - hackage.haskell.org   : Hadrian/cabal dependencies
#
# These are applied at session start, so set them in the environment's network
# settings and run this in a fresh session. Run from the repo root.

set -euo pipefail

BOOT_GHC="${BOOT_GHC:-9.10.1}"

echo "== 1. system build dependencies =="
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential autoconf automake python3 \
  libgmp-dev libnuma-dev libtinfo-dev curl git xz-utils

echo "== 2. boot GHC ($BOOT_GHC) + cabal via ghcup =="
if ! command -v ghcup >/dev/null; then
  export BOOTSTRAP_HASKELL_NONINTERACTIVE=1
  export BOOTSTRAP_HASKELL_MINIMAL=1
  curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
fi
# shellcheck disable=SC1090
source "${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/env"
ghcup install ghc "$BOOT_GHC"
ghcup set ghc "$BOOT_GHC"
ghcup install cabal latest
ghcup set cabal latest
cabal update

echo "== 3. boot-library submodules =="
git submodule update --init --recursive

echo "== 4. boot + configure =="
./boot
./configure

echo "== 5. build stage1 ghc (compiles the ghc library incl. the new modules) =="
./hadrian/build -j stage1:exe:ghc

echo "== done: stage1 ghc built; the platform-abstraction modules compiled =="
