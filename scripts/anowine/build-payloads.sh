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
#   mono/ano-mono-11.3.0                  wine-mono, renamed in place
#   licenses/{dxvk-macos,dxvk,mono}/      their license texts, word for word from
#                                         their sources (scripts/anowine/licenses.txt)
#
# Usage: build-payloads.sh <out-dir>
# Needs (Ubuntu 24.04): git, python3, meson, ninja, mingw-w64 (x86_64 and i686
# g++, win32 threads), glslangValidator, msitools, gcab, curl, xz.
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
# The wine-mono Wine 11.19 asks for (dlls/appwiz.cpl/addons.c), as in build-engine.sh.
MONO_VERSION=11.3.0
MONO_SHA=54a1b0111c3fe4b785eae688af94d27e64995707ad648b6fee8000381b80d298
MONO_URL=https://dl.winehq.org/wine/wine-mono/$MONO_VERSION/wine-mono-$MONO_VERSION-x86.tar.xz
# Its source, for its license (the binary tarball carries none).
MONO_GIT=https://github.com/wine-mono/wine-mono.git
MONO_COMMIT=17dd911a3ea04f21d7e4a8dcbff580ad520607eb   # tag wine-mono-11.3.0

[ -n "${1:-}" ] || die "usage: build-payloads.sh <out-dir>"
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ano-payloads.XXXXXX")
INFO=$OUT/payloads-info.txt
: > "$INFO"
info() { echo "$*" | tee -a "$INFO"; }

for tool in git python3 meson ninja glslangValidator x86_64-w64-mingw32-g++ i686-w64-mingw32-g++ msiinfo msibuild gcab curl; do
  command -v "$tool" > /dev/null || die "missing tool: $tool"
done
info "meson $(meson --version), $(x86_64-w64-mingw32-g++ --version | head -n 1)"
# DXVK's releases are built with the posix thread model (winpthreads; its README
# says so for Debian and Ubuntu): its mutexes and condition variables are std::.
for cc in x86_64-w64-mingw32-g++ i686-w64-mingw32-g++; do
  "$cc" -v 2>&1 | grep -qx 'Thread model: posix' || die "$cc does not use the posix thread model"
done
info "thread model: posix"

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
dxvk "$WORK/dxvk" 32 "$WORK/install-up" -Denable_d3d9=false -Denable_d3d10=false

rm -rf "$OUT/DXVK"
mkdir -p "$OUT/DXVK/x64" "$OUT/DXVK/x32"
for dll in d3d10core d3d11; do
  cp "$WORK/install-macos/x64/$dll.dll" "$OUT/DXVK/x64/"
  cp "$WORK/install-macos/x32/$dll.dll" "$OUT/DXVK/x32/"
done
cp "$WORK/install-up/x32/dxgi.dll" "$OUT/DXVK/x32/"
info "DXVK: $(cd "$OUT/DXVK" && find . -name '*.dll' | sort | tr '\n' ' ')"

# wine-mono cannot be rebuilt here (decision 7: names only): its tree is
# renamed in place, PE files at the same length and its support MSI and cabinet
# repacked (rename_binaries.py --tree).
curl -fsSL --retry 3 -o "$WORK/mono.tar.xz" "$MONO_URL"
echo "$MONO_SHA  $WORK/mono.tar.xz" | sha256sum -c - > /dev/null || die "wine-mono does not match its SHA-256 pin"
mkdir -p "$WORK/mono"
tar -xJf "$WORK/mono.tar.xz" -C "$WORK/mono"
python3 "$HERE/rename_binaries.py" --protect "$HERE/rename-protect-mono.txt" --map "$HERE/rename-map.txt" \
  --tree "$WORK/mono" > "$WORK/mono-rename.txt" 2>&1 || { tail -n 40 "$WORK/mono-rename.txt" >&2; die "the rename of wine-mono failed"; }
[ -d "$WORK/mono/ano-mono-$MONO_VERSION" ] || die "no ano-mono-$MONO_VERSION after the rename"
rm -rf "$OUT/mono"
mkdir -p "$OUT/mono"
mv "$WORK/mono/ano-mono-$MONO_VERSION" "$OUT/mono/"
info "mono: $(head -n 2 "$WORK/mono-rename.txt" | tr '\n' ' ')$(grep -c 'renamed in place' "$WORK/mono-rename.txt") PE files in place"
grep -E 'table |cabinet ' "$WORK/mono-rename.txt" | sed 's/^.*: /mono: /' | tee -a "$INFO"

# Plan 3c-5: each part's license, word for word from its source at its pin
# (git show reads the commit, not the renamed tree). build-engine.sh's
# write_licenses ships them (licenses.txt: payload:licenses/<component>).
rm -rf "$OUT/licenses"
mkdir -p "$OUT/licenses/dxvk-macos" "$OUT/licenses/dxvk" "$OUT/licenses/mono"
git -C "$WORK/dxvk-macos" show "$DXVK_MAC_COMMIT:LICENSE" > "$OUT/licenses/dxvk-macos/LICENSE"
git -C "$WORK/dxvk" show "$DXVK_UP_COMMIT:LICENSE" > "$OUT/licenses/dxvk/LICENSE"
mono_repo=${MONO_GIT#https://github.com/}
curl -fsSL --retry 3 -o "$OUT/licenses/mono/COPYING" \
  "https://raw.githubusercontent.com/${mono_repo%.git}/$MONO_COMMIT/COPYING"
for file in dxvk-macos/LICENSE dxvk/LICENSE mono/COPYING; do
  [ -s "$OUT/licenses/$file" ] || die "empty license text licenses/$file"
done
info "licenses: $(cd "$OUT/licenses" && find . -type f | sort | tr '\n' ' ')"

# Nothing that says wine may leave this script (the engine's gate checks again).
for part in DXVK mono; do
  python3 "$HERE/wine_tokens.py" "$OUT/$part" --allowlist "$HERE/wine-allowlist.txt" --out "$WORK/$part-tokens.tsv" \
    --gate > "$WORK/$part-gate.txt" || { cat "$WORK/$part-gate.txt" >&2; die "$part still says wine (above)"; }
  info "$part: $(tail -n 1 "$WORK/$part-gate.txt")"
done
