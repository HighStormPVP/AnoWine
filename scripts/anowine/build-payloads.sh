#!/bin/bash
# Builds, on Linux, the parts of Ano's engine 5.x that need nothing from Wine's
# own build (Plan 3c-2): DXVK from source, renamed by the owner's rule before it
# is built, so nothing in it says "wine". build-engine.sh takes the result
# through ANO_PAYLOADS.
#
#   DXVK/x64/{d3d10core,d3d11}.dll        Gcenx's DXVK-macOS (the async repack)
#   DXVK/x32/{d3d10core,d3d11}.dll        the same, 32-bit
#   DXVK/x32/dxgi.dll                     upstream DXVK 1.10.3: the repack has no
#                                         dxgi, and 32-bit bottles need DXVK's
#
# Usage: build-payloads.sh <out-dir>
# Needs (Ubuntu 24.04): git, python3, meson, ninja, mingw-w64 (x86_64 and i686
# g++, win32 threads), glslangValidator.
set -Eeuo pipefail
FAILED=
trap 'FAILED="line $LINENO: $BASH_COMMAND"' ERR
trap 'rc=$?; [ "$rc" = 0 ] || echo "::error::stopped (exit $rc)${FAILED:+ at $FAILED}" >&2' EXIT
die() { echo "::error::$*" >&2; trap - EXIT; exit 1; }

# The pins: the commits the published DXVK releases were built from.
DXVK_MAC_URL=https://github.com/Gcenx/DXVK-macOS.git
DXVK_MAC_COMMIT=8f1e28deed3ad30802f7e1bdff428ec14e6e7817   # v1.10.3-20230507-repack
DXVK_UP_URL=https://github.com/doitsujin/dxvk.git
DXVK_UP_COMMIT=e4fd5e9e8d335e8a2c0814829207cbd421f7e40e    # v1.10.3

[ -n "${1:-}" ] || die "usage: build-payloads.sh <out-dir>"
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ano-payloads.XXXXXX")
INFO=$OUT/payloads-info.txt
: > "$INFO"
info() { echo "$*" | tee -a "$INFO"; }

for tool in git python3 meson ninja glslangValidator x86_64-w64-mingw32-g++ i686-w64-mingw32-g++; do
  command -v "$tool" > /dev/null || die "missing tool: $tool"
done
info "meson $(meson --version), $(x86_64-w64-mingw32-g++ --version | head -n 1)"

# fetch <url> <commit> <dir>: exactly that commit, nothing else.
fetch() {
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" checkout -q FETCH_HEAD
  [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || die "$1: not at $2"
}

# rename <dir>: the owner's rule, with the map the engine uses (no protected
# text: DXVK has no Windows names that contain the letters).
rename() {
  python3 "$HERE/rename_sources.py" "$1" --map "$HERE/rename-map.txt" --report "$WORK/$(basename "$1").rename.txt" \
    > /dev/null || { cat "$WORK/$(basename "$1").rename.txt" >&2; die "rename of $(basename "$1") failed"; }
  info "$(basename "$1"): $(head -n 2 "$WORK/$(basename "$1").rename.txt" | tr '\n' ' ')"
}

# dxvk <src> <32|64> <prefix> [meson option]...: as DXVK's package-release.sh.
dxvk() {
  local src=$1 bits=$2 prefix=$3
  shift 3
  meson setup --cross-file "$src/build-win$bits.txt" --buildtype release --prefix "$prefix" --strip \
    --bindir "x$bits" --libdir "x$bits" -Dbuild_id=false "$@" "$src/build.$bits" "$src" > "$WORK/meson-$bits.log" 2>&1 \
    || { tail -n 40 "$WORK/meson-$bits.log" >&2; die "meson setup failed for $(basename "$src") $bits-bit"; }
  ninja -C "$src/build.$bits" install > "$WORK/ninja-$bits.log" 2>&1 \
    || { tail -n 60 "$WORK/ninja-$bits.log" >&2; die "ninja failed for $(basename "$src") $bits-bit"; }
}

fetch "$DXVK_MAC_URL" "$DXVK_MAC_COMMIT" "$WORK/dxvk-macos"
fetch "$DXVK_UP_URL" "$DXVK_UP_COMMIT" "$WORK/dxvk"
# Upstream 1.10.3 predates GCC 13 (patches/dxvk; the macOS branch has the fix).
for patch in "$HERE"/patches/dxvk/*.patch; do
  git -C "$WORK/dxvk" apply "$patch"
  info "dxvk patch: $(basename "$patch")"
done
rename "$WORK/dxvk-macos"
rename "$WORK/dxvk"

# The repack ships d3d10core and d3d11 only: no d3d9, and the engine's dxgi.
for bits in 64 32; do
  dxvk "$WORK/dxvk-macos" "$bits" "$WORK/install-macos" -Denable_d3d9=false -Denable_dxgi=false
done
dxvk "$WORK/dxvk" 32 "$WORK/install-up"

rm -rf "$OUT/DXVK"
mkdir -p "$OUT/DXVK/x64" "$OUT/DXVK/x32"
for dll in d3d10core d3d11; do
  cp "$WORK/install-macos/x64/$dll.dll" "$OUT/DXVK/x64/"
  cp "$WORK/install-macos/x32/$dll.dll" "$OUT/DXVK/x32/"
done
cp "$WORK/install-up/x32/dxgi.dll" "$OUT/DXVK/x32/"
info "DXVK: $(cd "$OUT/DXVK" && find . -name '*.dll' | sort | tr '\n' ' ')"

# Nothing that says wine may leave this script (the engine's gate checks again).
python3 "$HERE/wine_tokens.py" "$OUT/DXVK" --allowlist "$HERE/wine-allowlist.txt" --out "$WORK/tokens.tsv" --gate \
  > "$WORK/gate.txt" || { cat "$WORK/gate.txt" >&2; die "DXVK still says wine (above)"; }
info "DXVK: $(tail -n 1 "$WORK/gate.txt")"
