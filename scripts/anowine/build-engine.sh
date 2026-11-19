#!/bin/bash
# Builds the Wine engine Ano ships: Wine 11.19 with CrossOver's macOS patches
# (dappermint/winecx), GPTK-capable, packed as Libraries.tar.gz. It follows the
# recipe upstream Whisky used for its engine v4.8.3, with the same pinned
# sources, libraries, tools and settings, so the result can be compared file
# for file with upstream's (scripts/anowine/compare_runtimes.py).
#
# Plan 3b keeps upstream's names. Plan 3c adds its rename step after
# apply_patches.
#
# Usage: ANO_ENGINE_VERSION=4.8.3 build-engine.sh <out-dir>
#   ANO_ENGINE_VERSION  major.minor.patch stamped into WhiskyWineVersion.plist
#   ANO_ENGINE_WORK     work folder (default $RUNNER_TEMP/ano-engine)
# Needs macOS 15 on Apple silicon with Rosetta, Xcode with the macOS 15 SDK,
# nix, Homebrew's mingw-w64, cmake, git and python3. ccache is used if present.
set -euo pipefail

# The pins: exactly what upstream's v4.8.3 was built from. The workflow reads
# WINECX_COMMIT from this line for its compiler-cache key.
WINECX_URL=https://github.com/dappermint/winecx.git
WINECX_COMMIT=9f3f6447844add700bc0dde650e4f398fd5f69ab
NIXPKGS_REV=ac62194c3917d5f474c1a844b6fd6da2db95077d
FLOOR=15.0
export MACOSX_DEPLOYMENT_TARGET=$FLOOR

die() { echo "::error::$*" >&2; exit 1; }

OUT=${1:-}
[ -n "$OUT" ] || die "usage: ANO_ENGINE_VERSION=x.y.z build-engine.sh <out-dir>"
VERSION=${ANO_ENGINE_VERSION:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ANO_ENGINE_VERSION must be major.minor.patch, not '$VERSION'"
WORK=${ANO_ENGINE_WORK:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ano-engine}
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)
INFO="$WORK/build-info.txt"
: > "$INFO"

# info <text>: a line for the log and for build-info.txt.
info() { echo "$*" | tee -a "$INFO"; }

# ---------------------------------------------------------------------------
# check_host: the machine can build this engine; record every tool version.
# ---------------------------------------------------------------------------
check_host() {
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "needs macOS on Apple silicon"
  /usr/bin/arch -x86_64 /usr/bin/true || die "Rosetta does not run x86_64 programs here"
  local sdk tool
  sdk=$(xcrun --sdk macosx --show-sdk-version)
  [ "${sdk%%.*}" = "${FLOOR%%.*}" ] \
    || die "the SDK is macOS $sdk; building for the macOS $FLOOR floor needs a macOS ${FLOOR%%.*} SDK"
  for tool in nix x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc x86_64-w64-mingw32-strip cmake git python3; do
    command -v "$tool" > /dev/null || die "missing tool: $tool"
  done
  info "engine version: $VERSION"
  info "image: ${ImageOS:-?} ${ImageVersion:-?}"
  info "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  info "xcode: $(xcode-select -p)"
  info "sdk: $sdk"
  info "clang: $(clang --version | head -1)"
  info "x86_64 mingw gcc: $(x86_64-w64-mingw32-gcc --version | head -1)"
  info "i686 mingw gcc: $(i686-w64-mingw32-gcc --version | head -1)"
  info "mingw binutils: $(x86_64-w64-mingw32-ld --version | head -1)"
  info "brew mingw-w64: $(brew list --versions mingw-w64 2> /dev/null || echo 'not from brew')"
  info "cmake: $(cmake --version | head -1)"
  info "nix: $(nix --version)"
  if command -v ccache > /dev/null; then
    info "ccache: $(ccache --version | head -1)"
  else
    info "ccache: none"
  fi
}

PHASES="check_host"

for phase in $PHASES; do
  echo "== $phase"
  started=$SECONDS
  "$phase"
  info "phase $phase: $((SECONDS - started))s"
done
die "not implemented: build-engine.sh stops after check_host (Plan 3b, Task 2 RED)"
