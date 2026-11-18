#!/bin/bash
# Builds the modules Ano's runtime replaces in upstream's engine (x86_64 and
# i386, like the rest of the runtime, which runs under Rosetta on Apple
# Silicon), from the engine's own source: dappermint/winecx at the commit the
# engine was built from, with the engine's out-of-tree patches (patches/engine/).
# These are the modules that start a renamed Wine program by name:
#   ntdll.so      starts the loader (ano-core) and the boot program (ano-boot)
#                 and keeps its program name and arguments (ntdll-no-proctitle.patch)
#   user32.dll    starts ano-boot.exe to end the session
#   services.exe  starts ano-device.exe to host drivers
#   winedbg.exe   skips crash dialogs for ano-device.exe
#   ano-boot.exe, ano-device.exe  the renamed programs themselves
#   wine.inf      installs ano-boot.exe and ano-device.exe into bottles
# See scripts/anowine/patches/.
#
# Usage: scripts/anowine/build-modules.sh <out-dir> [patch ...]
# The engine's patches are applied first, then the given ones (-p1, against the
# source root), in order; with none the result is the engine's own modules.
# Produces <out-dir>/Wine/... laid out like the runtime, plus
# <out-dir>/tests/*.exe built from tests/*.c. macOS only. The build settings
# that reach these modules follow the engine's build (frankea/winecx-gptk
# .github/workflows/build.yml at 12af865); libraries none of these modules use
# are left out. check-modules.sh compares the result with the engine.
set -euo pipefail

OUT="$(mkdir -p "${1:?usage: build-modules.sh <out-dir> [patch ...]}" && cd "$1" && pwd)"
shift
PATCHES=()
for p in "$@"; do PATCHES+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"); done
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- pinned inputs ----------------------------------------------------------
SRC_REPO="https://github.com/dappermint/winecx.git"
SRC_COMMIT="9f3f6447844add700bc0dde650e4f398fd5f69ab"
SRC_VERSION="Wine version 11.19"
MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20261104/llvm-mingw-20261104-ucrt-macos-universal.tar.xz"
MINGW_SHA256="66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c"
# Make targets, and each built file with the runtime path it replaces.
TARGETS="dlls/ntdll/ntdll.so dlls/user32/all programs/services/all programs/wineboot/all
  programs/winedevice/all programs/winedbg/all loader/wine.inf"
OUTPUTS="
dlls/ntdll/ntdll.so                              lib/wine/x86_64-unix/ntdll.so
dlls/user32/x86_64-windows/user32.dll            lib/wine/x86_64-windows/user32.dll
dlls/user32/i386-windows/user32.dll              lib/wine/i386-windows/user32.dll
programs/services/x86_64-windows/services.exe    lib/wine/x86_64-windows/services.exe
programs/wineboot/x86_64-windows/ano-boot.exe    lib/wine/x86_64-windows/ano-boot.exe
programs/winedevice/x86_64-windows/ano-device.exe lib/wine/x86_64-windows/ano-device.exe
programs/winedevice/i386-windows/ano-device.exe  lib/wine/i386-windows/ano-device.exe
programs/winedbg/x86_64-windows/winedbg.exe      lib/wine/x86_64-windows/winedbg.exe
programs/winedbg/i386-windows/winedbg.exe        lib/wine/i386-windows/winedbg.exe
loader/wine.inf                                  share/wine/wine.inf
"
# -----------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-modules-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "== fetch and verify sources"
SRC="$WORK/winecx"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$SRC_REPO" "$SRC_COMMIT"
git -C "$SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$SRC" rev-parse HEAD)" = "$SRC_COMMIT" ] || { echo "error: source is not $SRC_COMMIT" >&2; exit 1; }
[ "$(cat "$SRC/VERSION")" = "$SRC_VERSION" ] || { echo "error: source VERSION is not '$SRC_VERSION'" >&2; exit 1; }
curl -fsSL -o "$WORK/mingw.tar.xz" "$MINGW_URL"
echo "$MINGW_SHA256  $WORK/mingw.tar.xz" | shasum -a 256 -c -
mkdir "$WORK/mingw" && tar -xJf "$WORK/mingw.tar.xz" -C "$WORK/mingw" --strip-components 1

for p in "$HERE"/patches/engine/*.patch ${PATCHES[@]+"${PATCHES[@]}"}; do
  echo "== apply $(basename "$p")"
  patch -d "$SRC" -p1 --forward --batch --fuzz=0 < "$p"
done

# Wine needs bison >= 3; macOS ships 2.3.
command -v brew >/dev/null && { brew list bison >/dev/null 2>&1 || brew install bison; }
BISON_BIN="$(brew --prefix bison)/bin"

echo "== configure and build (x86_64 under Rosetta)"
# The engine's settings: macOS 15 floor, enforced as an error for APIs above
# it; pipe2 refused (it is above the floor, and every caller has a fallback).
arch -x86_64 /usr/bin/env PATH="$WORK/mingw/bin:$BISON_BIN:$PATH" \
  MACOSX_DEPLOYMENT_TARGET=15.0 ac_cv_func_pipe2=no \
  CFLAGS="-O3 -Wno-error=implicit-function-declaration -Werror=unguarded-availability-new" \
  CROSSCFLAGS=-O3 /bin/bash -c '
  set -euo pipefail
  cd "$1"; shift
  ./configure --enable-archs=i386,x86_64 \
    --disable-tests --disable-winebth_sys --disable-winemenubuilder \
    --without-alsa --without-capi --with-coreaudio --without-cups --without-dbus \
    --without-ffmpeg --without-fontconfig --without-freetype --without-gettext \
    --without-gettextpo --without-gphoto --without-gnutls --without-gssapi \
    --without-gstreamer --without-inotify --without-krb5 --without-netapi \
    --without-opencl --without-opengl --without-oss --without-pcap --without-pulse \
    --without-sane --without-sdl --without-udev --without-usb --without-v4l2 \
    --without-vulkan --without-wayland --without-x \
    > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j"$(sysctl -n hw.ncpu)" "$@" > make.log 2>&1 || { tail -60 make.log; exit 1; }
' _ "$SRC" $TARGETS

echo "== collect"
echo "$OUTPUTS" | while read -r built dest; do
  [ -n "$built" ] || continue
  [ -f "$SRC/$built" ] || { echo "error: build did not produce $built" >&2; exit 1; }
  mkdir -p "$OUT/Wine/$(dirname "$dest")"
  cp "$SRC/$built" "$OUT/Wine/$dest"
  echo "  $dest  $(shasum -a 256 "$OUT/Wine/$dest" | awk '{print $1}')"
done
codesign --force --sign - "$OUT/Wine/lib/wine/x86_64-unix/ntdll.so"
lipo -archs "$OUT/Wine/lib/wine/x86_64-unix/ntdll.so"

# Test programs for scripts/anowine/check-*.sh (not shipped).
mkdir -p "$OUT/tests"
for c in "$HERE"/tests/*.c; do
  "$WORK/mingw/bin/x86_64-w64-mingw32-clang" -O2 -o "$OUT/tests/$(basename "${c%.c}").exe" "$c"
done
