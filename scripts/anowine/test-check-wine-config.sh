#!/bin/bash
# Tests check-wine-config.sh: a Wine build folder whose configure found every
# library the engine needs passes; one that lost any of them fails and names it.
# Runs on Linux (AnoWine Hygiene) and macOS.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

full_config() {
  printf '%s\n' '#define HAVE_FFMPEG 1' \
    '#define SONAME_LIBSDL2 "libSDL2-2.0.0.dylib"' \
    '#define SONAME_LIBFREETYPE "libfreetype.6.dylib"' \
    '#define SONAME_LIBGNUTLS "libgnutls.30.dylib"' \
    '#define SONAME_LIBVULKAN "libMoltenVK.dylib"'
}
build="$tmp/build"
mkdir -p "$build/include"
printf 'GSTREAMER_LIBS = -lgstreamer-1.0 -lgobject-2.0\n' > "$build/Makefile"

fail=0
check() {  # check <expected exit> <text the output must contain> <label>
  local code=0 out
  out=$(bash "$here/check-wine-config.sh" "$build" 2>&1) || code=$?
  if [ "$code" = "$1" ] && grep -qF "$2" <<< "$out"; then
    echo "ok: $3"
  else
    echo "FAIL: $3 (exit $code): $out"
    fail=1
  fi
}

full_config > "$build/include/config.h"
check 0 "ffmpeg, gstreamer, SDL2, FreeType, GnuTLS and MoltenVK found" "everything found"

for gone in HAVE_FFMPEG SONAME_LIBSDL2 SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBVULKAN; do
  full_config | grep -v "$gone" > "$build/include/config.h"
  case $gone in
    HAVE_FFMPEG) name=ffmpeg ;; SONAME_LIBSDL2) name=SDL2 ;; SONAME_LIBFREETYPE) name=FreeType ;;
    SONAME_LIBGNUTLS) name=GnuTLS ;; SONAME_LIBVULKAN) name=MoltenVK ;;
  esac
  check 1 "did not find $name" "$gone missing fails"
done

# A Vulkan loader found on the way would replace MoltenVK.
full_config | sed 's/libMoltenVK.dylib/libvulkan.1.dylib/' > "$build/include/config.h"
check 1 "did not find MoltenVK" "another Vulkan library fails"

full_config > "$build/include/config.h"
printf 'GSTREAMER_LIBS = \n' > "$build/Makefile"
check 1 "did not find gstreamer" "gstreamer missing fails"

exit $fail
