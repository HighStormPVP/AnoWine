#!/bin/bash
# Builds the Wine 11.0 modules AnoWine's runtime replaces (x86_64 and i386,
# like the rest of the runtime, which runs under Rosetta on Apple Silicon).
# These are the modules that start a renamed Wine program by name:
#   ntdll.so      starts the loader (ano-core) and the boot program (ano-boot)
#                 and keeps its program name (ntdll-no-proctitle.patch)
#   user32.dll    starts ano-boot.exe to end the session
#   services.exe  starts ano-device.exe to host drivers
#   winedbg.exe   skips crash dialogs for ano-device.exe
#   ano-boot.exe, ano-device.exe  the renamed programs themselves
#   wine.inf      installs ano-boot.exe and ano-device.exe into bottles
# See scripts/anowine/patches/.
#
# Usage: scripts/anowine/build-modules.sh <out-dir> [patch ...]
# Patches (-p1, against the Wine source root) are applied in order; with none
# the result is plain Wine 11.0. Produces <out-dir>/Wine/... laid out like the
# runtime, plus <out-dir>/tests/*.exe built from tests/*.c. macOS only.
# Configure options follow Gcenx's wine-stable recipe (the runtime's source),
# minus libraries none of these modules use.
set -euo pipefail

OUT="$(mkdir -p "${1:?usage: build-modules.sh <out-dir> [patch ...]}" && cd "$1" && pwd)"
shift
PATCHES=()
for p in "$@"; do PATCHES+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"); done
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- pinned inputs ----------------------------------------------------------
SRC_URL="https://github.com/wine-mirror/wine/archive/wine-11.0.tar.gz"
SRC_SHA256="f09e8153aa46a581d2b56a5b1363b04832070b9409d9244a68cf482b243ff14a"
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
curl -fsSL -o "$WORK/wine.tar.gz" "$SRC_URL"
echo "$SRC_SHA256  $WORK/wine.tar.gz" | shasum -a 256 -c -
curl -fsSL -o "$WORK/mingw.tar.xz" "$MINGW_URL"
echo "$MINGW_SHA256  $WORK/mingw.tar.xz" | shasum -a 256 -c -
tar -xzf "$WORK/wine.tar.gz" -C "$WORK"
mkdir "$WORK/mingw" && tar -xJf "$WORK/mingw.tar.xz" -C "$WORK/mingw" --strip-components 1
SRC="$WORK/wine-wine-11.0"

for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
  echo "== apply $(basename "$p")"
  patch -d "$SRC" -p1 --forward --batch < "$p"
done

# Wine needs bison >= 3; macOS ships 2.3.
command -v brew >/dev/null && { brew list bison >/dev/null 2>&1 || brew install bison; }
BISON_BIN="$(brew --prefix bison)/bin"

echo "== configure and build (x86_64 under Rosetta)"
arch -x86_64 /usr/bin/env PATH="$WORK/mingw/bin:$BISON_BIN:$PATH" \
  MACOSX_DEPLOYMENT_TARGET=10.15 CFLAGS=-O2 CROSSCFLAGS=-O2 /bin/bash -c '
  set -euo pipefail
  cd "$1"; shift
  ./configure --enable-archs=i386,x86_64 --enable-win64 \
    --disable-tests --disable-winebth_sys --disable-winemenubuilder \
    --without-alsa --without-capi --with-coreaudio --without-dbus --without-ffmpeg \
    --without-fontconfig --without-freetype --without-gettext --without-gettextpo \
    --without-gphoto --without-gnutls --without-gssapi --without-gstreamer \
    --without-inotify --without-krb5 --without-netapi --without-opengl --without-oss \
    --without-pulse --without-sane --without-sdl --without-udev --with-unwind \
    --without-usb --without-v4l2 --without-vulkan --without-wayland --without-x \
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
