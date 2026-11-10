#!/bin/bash
# Builds Wine 11.0's ntdll.so for AnoWine's runtime (x86_64; on Apple Silicon
# it runs under Rosetta like the rest of the runtime). ntdll.so is what starts
# the Wine loader `lib/wine/x86_64-unix/wine` by name, so renaming the loader
# means rebuilding it (scripts/anowine/patches/ntdll-ano-core.patch).
#
# Usage: scripts/anowine/build-ntdll.sh <out-dir> [patch ...]
# Patches (-p1, against the Wine source root) are applied in order; with none
# the result is plain Wine 11.0. Produces <out-dir>/ntdll.so. macOS only.
# Configure options follow Gcenx's wine-stable recipe (the runtime's source),
# minus libraries ntdll.so does not use.
set -euo pipefail

OUT="$(mkdir -p "${1:?usage: build-ntdll.sh <out-dir> [patch ...]}" && cd "$1" && pwd)"
shift
PATCHES=()
for p in "$@"; do PATCHES+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"); done

# ---- pinned inputs ----------------------------------------------------------
SRC_URL="https://github.com/wine-mirror/wine/archive/wine-11.0.tar.gz"
SRC_SHA256="f09e8153aa46a581d2b56a5b1363b04832070b9409d9244a68cf482b243ff14a"
MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20261104/llvm-mingw-20261104-ucrt-macos-universal.tar.xz"
MINGW_SHA256="66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c"
# -----------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-ntdll-XXXXXX")"
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
  cd "$1"
  ./configure --enable-archs=i386,x86_64 --enable-win64 \
    --disable-tests --disable-winebth_sys --disable-winemenubuilder \
    --without-alsa --without-capi --with-coreaudio --without-dbus --without-ffmpeg \
    --without-fontconfig --without-freetype --without-gettext --without-gettextpo \
    --without-gphoto --without-gnutls --without-gssapi --without-gstreamer \
    --without-inotify --without-krb5 --without-netapi --without-opengl --without-oss \
    --without-pulse --without-sane --without-sdl --without-udev --with-unwind \
    --without-usb --without-v4l2 --without-vulkan --without-wayland --without-x \
    > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j"$(sysctl -n hw.ncpu)" dlls/ntdll/ntdll.so > make.log 2>&1 || { tail -60 make.log; exit 1; }
' _ "$SRC"

cp "$SRC/dlls/ntdll/ntdll.so" "$OUT/ntdll.so"
codesign --force --sign - "$OUT/ntdll.so"
lipo -archs "$OUT/ntdll.so"
echo "SHA-256: $(shasum -a 256 "$OUT/ntdll.so" | awk '{print $1}')"
