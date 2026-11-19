#!/bin/bash
# Usage: check-wine-config.sh <wine build folder>
# Stops an engine build whose configure lost a library the engine needs.
# Wine's configure only warns for most of them, and build-engine.sh presets
# the sonames of FreeType and GnuTLS, which silences even Wine's own FreeType
# error: the only proof the library was found is the define in config.h.
set -euo pipefail
build=${1:?usage: check-wine-config.sh <wine build folder>}
config="$build/include/config.h"
[ -f "$config" ] || { echo "::error::no $config" >&2; exit 1; }

missing=""
need() {  # need <name> <what is lost without it> <extended regex for config.h>
  grep -qE "$3" "$config" || missing="$missing
::error::configure did not find $1: $2"
}
need ffmpeg "no video decoding (winedmo)" '^#define HAVE_FFMPEG 1'
need SDL2 "no game controllers (winebus)" '^#define SONAME_LIBSDL2 '
need FreeType "no TrueType fonts" '^#define SONAME_LIBFREETYPE '
need GnuTLS "no TLS for schannel and bcrypt (Steam's login)" '^#define SONAME_LIBGNUTLS '
need MoltenVK "no Vulkan, or another Vulkan library instead of MoltenVK" \
  '^#define SONAME_LIBVULKAN "libMoltenVK\.dylib"'
grep -qE '^GSTREAMER_LIBS *= *[^ ]' "$build/Makefile" || missing="$missing
::error::configure did not find gstreamer: no media (winegstreamer)"

if [ -n "$missing" ]; then
  echo "${missing#?}" >&2
  exit 1
fi
echo "configure: ffmpeg, gstreamer, SDL2, FreeType, GnuTLS and MoltenVK found"
