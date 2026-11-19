#!/bin/bash
# Builds the Wine engine Ano ships: Wine 11.19 with CrossOver's macOS patches
# (dappermint/winecx), GPTK-capable, packed as Libraries.tar.gz. It follows the
# recipe upstream Whisky used for its engine v4.8.3, with the same pinned
# sources, libraries, tools and settings, so the result can be compared file
# for file with upstream's (scripts/anowine/compare_runtimes.py).
#
# Version 4.x keeps upstream's names (Plan 3b: equal to upstream's v4.8.3).
# Version 5 and later is Ano's engine (Plan 3c): the Wine tree is renamed by
# rename_sources.py after apply_patches, so nothing it builds says "wine",
# and the layout is Libraries/Ano with bin/ano-loader and bin/ano-server.
# 3c-1 builds Wine's own parts only: no DXVK, DXMT, wine-mono or Gecko.
#
# Usage: ANO_ENGINE_VERSION=4.8.3 build-engine.sh <out-dir>
#   ANO_ENGINE_VERSION  major.minor.patch stamped into the version plist
#   ANO_ENGINE_WORK     work folder (default $RUNNER_TEMP/ano-engine)
# Writes <out-dir>/Libraries.tar.gz, Libraries.tar.gz.sha256, the version plist
# (WhiskyWineVersion.plist, or AnoRuntimeVersion.plist from 5.0) and
# build-info.txt. Logs go to <work>/logs.
# Needs macOS 15 on Apple silicon with Rosetta, Xcode with the macOS 15 SDK,
# nix, Homebrew's mingw-w64, cmake, git and python3. ccache is used if present.
set -Eeuo pipefail
# A command that fails without a message still names its phase and line.
FAILED=
trap 'FAILED="line $LINENO: $BASH_COMMAND"' ERR
trap 'rc=$?; [ "$rc" = 0 ] || echo "::error::stopped (exit $rc) in ${phase:-setup}${FAILED:+ at $FAILED}" >&2' EXIT

# The pins: exactly what upstream's v4.8.3 was built from. The workflow reads
# WINECX_COMMIT from this line for its compiler-cache key.
WINECX_URL=https://github.com/dappermint/winecx.git
WINECX_COMMIT=9f3f6447844add700bc0dde650e4f398fd5f69ab
NIXPKGS_REV=ac62194c3917d5f474c1a844b6fd6da2db95077d
FLOOR=15.0
export MACOSX_DEPLOYMENT_TARGET=$FLOOR
FAUDIO_VERSION=26.10
MONO_VERSION=11.3.0
MONO_SHA=54a1b0111c3fe4b785eae688af94d27e64995707ad648b6fee8000381b80d298
GECKO_VERSION=2.47.4
GECKO_X86_SHA=2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
GECKO_X64_SHA=fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814
SDL2_VERSION=2.32.10
SDL2_SHA=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
DXVK_VERSION=1.10.3
DXVK_MAC_URL=https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz
DXVK_MAC_SHA=acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477
DXVK_UP_URL=https://github.com/doitsujin/dxvk/releases/download/v1.10.3/dxvk-1.10.3.tar.gz
DXVK_UP_SHA=8d1a3c912761b450c879f98478ae64f6f6639e40ce6848170a0f6b8596fd53c6
DXMT_VERSION=0.80
DXMT_URL=https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz
DXMT_SHA=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d
MOLTENVK_URL=https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar
MOLTENVK_SHA=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
# rename_binaries.py rewrites the engine's fonts with it (5.x only).
FONTTOOLS_VERSION=4.57.0

# Upstream's recipe files (frankea/winecx-gptk has no license, so they are
# downloaded at the commit that built v4.8.3, never stored here): one Wine
# patch, the two GPTK shims and the smoke-test programs.
RECIPE_BASE=https://raw.githubusercontent.com/frankea/winecx-gptk/12af86593bc5195c5015ca460dc1bbc8e81f3b13
RECIPE_FILES="
d36bfa79c78b0fac47e24aa77d397d73548620a87ae74f4914b58b1194ddd861 patches/0001-ntdll-kernelbase-keep-the-fiber-pointer-at-gs-0x20-on-macOS.patch
94420063c1a194b6bd85d3ff123b03a1b95cc4d7f9671bac7be73c929023f787 gptk-video/d3d12shim.c
a520ea877f2ba3faea6e202aec03f4852909a1ed5a78a01aa2b75f1dec7bad09 gptk-video/d3d12shim.def
361b247d72e4fbed18ea47336cc03b2e0df57e62191ab2cb1bd6f0249463537c gptk-video/dxgishim.c
e2ea0bd01a798180d7b8f762cbfc1567672ef47f01ff3f6bd93f25a9a8e87fe0 gptk-video/dxgishim.def
fe6de98e1806833c768d09427f971a58b0e615de2f2820176c9f72e04dfa3854 gptk-video/yuvblit.h
2420818c6b0f9bc39ee71ec881569389788cd837204e716d2ab9a5e7adcdac2c tests/winmsg.c
0a2946185719d947cc3c9dd18894b4e5455cecd496b467dfc73b85913f52b7b9 tests/flsgetvalue2.c
d7a84052adf54987b6f112182dad3875abc1affef2e3f497943fe5098d2ca528 tests/mfprobe.c
dbecc84a08029c64b8e56457fea2bf00d0fc8362e295c575aa6a311f56b081ad tests/dlopenall.c
"

# x86_64 libraries from nixpkgs that the engine links or loads. ffmpeg-headless
# (not ffmpeg) keeps SDL and X11 out of the closure. glib and orc are named
# because pkg-config only finds gstreamer's requirements on PKG_CONFIG_PATH.
NIX_X86_PACKAGES="freetype gnutls libpng zlib brotli bzip2 nettle libtasn1 libidn2 p11-kit libunistring gmp
  vulkan-headers ffmpeg-headless glib orc gst_all_1.gstreamer gst_all_1.gst-plugins-base
  gst_all_1.gst-plugins-good gst_all_1.gst-plugins-bad gst_all_1.gst-libav"

# Configure switches both Wine configures share: no X11, Wayland or Linux-only
# back ends, no tests.
WINE_WITHOUT="--without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane
  --without-usb --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups"

die() { echo "::error::$*" >&2; trap - EXIT; exit 1; }

OUT=${1:-}
[ -n "$OUT" ] || die "usage: ANO_ENGINE_VERSION=x.y.z build-engine.sh <out-dir>"
VERSION=${ANO_ENGINE_VERSION:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ANO_ENGINE_VERSION must be major.minor.patch, not '$VERSION'"
HERE=$(cd "$(dirname "$0")" && pwd)
# The names of each layout. Folder names end up inside the binaries (__FILE__
# paths, the install prefix), so 5.x uses none with "wine".
if [ "${VERSION%%.*}" -ge 5 ]; then
  RENAME=1 SRC=ano-src PREFIX=/opt/ano TOP=Libraries/Ano MOD=ano PLIST=AnoRuntimeVersion.plist
  LOADER=ano-core SERVER=ano-server BUILTIN="Ano builtin DLL"
else
  RENAME=0 SRC=winecx PREFIX=/opt/whiskywine TOP=Libraries/Wine MOD=wine PLIST=WhiskyWineVersion.plist
  LOADER=wine SERVER=wineserver BUILTIN="Wine builtin DLL"
fi
WORK=${ANO_ENGINE_WORK:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ano-engine}
mkdir -p "$WORK/logs" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)
LOGS="$WORK/logs"
INFO="$WORK/build-info.txt"
: > "$INFO"
# SDL2's sources are compiled by absolute path, so it is built where upstream
# built it (the runner's temp folder) to keep any embedded path the same.
SDL_TEMP=${RUNNER_TEMP:-$WORK}
SDL2_PREFIX="$SDL_TEMP/sdl2-x86_64"
NCPU=$(sysctl -n hw.logicalcpu)
CCACHE=""

# info <text>: a line for the log and for build-info.txt.
info() { echo "$*" | tee -a "$INFO"; }

# logged <name> <command...>: runs the command with its output in logs/<name>.log;
# on failure shows the errors and the end of the log, then stops.
logged() {
  local log="$LOGS/$1.log"
  shift
  if ! "$@" > "$log" 2>&1; then
    grep -nE 'error:|Error [0-9]+|\*\*\*' "$log" | tail -n 30 >&2 || true
    tail -n 60 "$log" >&2
    die "failed: $* (log: $log)"
  fi
}

# fetch <url> <file> <sha256>: download and check.
fetch() {
  # Any error is retried: a long GitHub release download can drop mid-transfer
  # (curl 56), which plain --retry does not count as transient.
  curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 30 -o "$2" "$1" \
    || die "download failed: $1"
  local got
  got=$(shasum -a 256 "$2" | cut -d' ' -f1)
  [ "$got" = "$3" ] || { rm -f "$2"; die "SHA-256 of $1 is $got, expected $3"; }
}

# nix_paths <installable...>: store paths of nix builds from the pinned nixpkgs.
nix_paths() { nix build --no-link --print-out-paths "$@"; }

# ---------------------------------------------------------------------------
# check_host: the machine can build this engine; record every tool version.
# ---------------------------------------------------------------------------
check_host() {
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "needs macOS on Apple silicon"
  /usr/bin/arch -x86_64 /usr/bin/true || die "Rosetta does not run x86_64 programs here"
  local sdk tool real
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
  if ! command -v ccache > /dev/null; then
    info "ccache: none"
    return
  fi
  info "ccache: $(ccache --version | head -1)"
  # Content checks survive image updates; the sloppiness covers Wine's
  # __DATE__/__TIME__ users on a fresh checkout; paths under the work folder are
  # hashed relative.
  # Unlike upstream, the folder stays in the hash of compiles with debug info
  # (lsteamclient's -g): their DWARF names the folder they were compiled in, and
  # the linker copies it into lsteamclient.so, so a hit from another folder
  # would put a wrong path in the engine. And hits are copied, not cloned: a
  # clone keeps the cached file's old modification time, so `make install-lib`
  # saw every object as stale and relinked the whole engine (30 minutes).
  export CCACHE_DIR="$HOME/.ccache" CCACHE_MAXSIZE=4G CCACHE_COMPILERCHECK=content
  export CCACHE_SLOPPINESS=time_macros,locale,include_file_mtime,include_file_ctime
  export CCACHE_BASEDIR="$WORK" CCACHE_INODECACHE=1
  CCACHE=ccache
  # The mingw compilers go through ccache by wrappers that name the real
  # compiler; a wrapper that looked itself up on PATH would find itself.
  mkdir -p "$WORK/ccache-bin"
  for tool in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
    real=$(command -v "$tool")
    printf '#!/bin/sh\nexec ccache "%s" "$@"\n' "$real" > "$WORK/ccache-bin/$tool"
    chmod +x "$WORK/ccache-bin/$tool"
    "$WORK/ccache-bin/$tool" --version > /dev/null
  done
}

# ---------------------------------------------------------------------------
# fetch_sources: Wine (a full clone: Wine's version string is `git describe`)
# and upstream's recipe files.
# ---------------------------------------------------------------------------
fetch_sources() {
  rm -rf "$SRC" recipe
  logged clone git clone "$WINECX_URL" "$SRC"
  git -C "$SRC" checkout --quiet --detach "$WINECX_COMMIT"
  info "winecx: $WINECX_COMMIT ($(git -C "$SRC" describe --tags 2> /dev/null || echo 'no tag')) in $SRC"
  local sha path
  while read -r sha path; do
    [ -n "$sha" ] || continue
    mkdir -p "recipe/$(dirname "$path")"
    fetch "$RECIPE_BASE/$path" "recipe/$path" "$sha"
  done <<< "$RECIPE_FILES"
  # FAudio is part of the Wine tree; only check it is the pinned release.
  local header=$SRC/libs/faudio/include/FAudio.h major minor
  major=$(sed -nE 's/^#define FAUDIO_MAJOR_VERSION[[:space:]]+([0-9]+).*/\1/p' "$header")
  minor=$(sed -nE 's/^#define FAUDIO_MINOR_VERSION[[:space:]]+([0-9]+).*/\1/p' "$header")
  [ "$major.$minor" = "$FAUDIO_VERSION" ] || die "FAudio in the tree is $major.$minor, not $FAUDIO_VERSION"
  info "faudio: $major.$minor"
}

# ---------------------------------------------------------------------------
# apply_patches: upstream's out-of-tree patches, in name order.
# ---------------------------------------------------------------------------
apply_patches() {
  local patch
  for patch in recipe/patches/*.patch; do
    [ -e "$patch" ] || continue
    git -C "$SRC" apply --verbose "$WORK/$patch"
    info "patch: $(basename "$patch")"
  done
}

# ---------------------------------------------------------------------------
# rename_sources (5.x): the owner's naming rule over the whole tree, then
# Ano's own patches (written against the renamed tree), then the binary files
# that ship: the fonts (fontTools) and pidgen's placeholder resource. Other
# binary files with "wine" are test data (not built) or ICU's dictionary.
# ---------------------------------------------------------------------------
rename_sources() {
  [ "$RENAME" = 1 ] || return 0
  local patch font fonts=() code=0
  python3 "$HERE/rename_sources.py" "$SRC" --protect "$HERE/rename-protect.txt" --map "$HERE/rename-map.txt" \
    --report "$LOGS/rename.txt" > /dev/null || code=$?
  { grep -v $'^binary\t' "$LOGS/rename.txt" || true; } | sed 's/^/rename: /' | tee -a "$INFO"
  { grep $'^binary\t' "$LOGS/rename.txt" || true; } | cut -f2 | sed 's/^/rename: binary with wine: /'
  [ "$code" = 0 ] || die "rename_sources.py exit $code: a rule conflicts (see above)"
  for patch in "$HERE"/patches/rename/*.patch; do
    git -C "$SRC" apply --verbose "$patch"
    info "rename patch: $(basename "$patch")"
  done
  rm -rf "$WORK/venv"
  python3 -m venv "$WORK/venv"
  logged fonttools "$WORK/venv/bin/pip" install --quiet "fonttools==$FONTTOOLS_VERSION"
  for font in "$SRC"/fonts/*.ttf; do fonts+=(--font "$font"); done
  logged rename-binaries "$WORK/venv/bin/python" "$HERE/rename_binaries.py" --protect "$HERE/rename-protect.txt" \
    --map "$HERE/rename-map.txt" "${fonts[@]}" --padded "$SRC/dlls/pidgen/bink.bin"
  info "rename: fontTools $FONTTOOLS_VERSION, $(grep -c . "$LOGS/rename-binaries.log") changes in" \
    "$((${#fonts[@]} / 2)) fonts and bink.bin"
}

# ---------------------------------------------------------------------------
# nix_inputs: build tools for the host and x86_64 libraries for the engine,
# from the pinned nixpkgs.
# ---------------------------------------------------------------------------
nix_inputs() {
  local np="github:NixOS/nixpkgs/$NIXPKGS_REV" tool package output path found
  NIX_TOOL_PATH=""
  for tool in $(nix_paths "$np#bison" "$np#flex" "$np#pkg-config"); do
    NIX_TOOL_PATH="$tool/bin:$NIX_TOOL_PATH"
  done
  # A package's libraries can sit in any of its dev, out and lib outputs
  # (ffmpeg keeps its dylibs in lib); outputs a package lacks are skipped.
  : > store-outs.txt
  for package in $NIX_X86_PACKAGES; do
    found=0
    for output in dev out lib; do
      if path=$(nix_paths "$np#legacyPackages.x86_64-darwin.$package.$output" 2> /dev/null); then
        echo "$path" >> store-outs.txt
        found=1
      fi
    done
    [ "$found" = 1 ] || die "nixpkgs gave no output for x86_64-darwin $package"
  done
  NIX_PKG_CONFIG_PATH="" NIX_INCS="" NIX_LDFS=""
  while read -r path; do
    [ -d "$path/lib/pkgconfig" ] && NIX_PKG_CONFIG_PATH="$path/lib/pkgconfig:$NIX_PKG_CONFIG_PATH"
    [ -d "$path/include" ] && NIX_INCS="$NIX_INCS -I$path/include"
    [ -d "$path/lib" ] && NIX_LDFS="$NIX_LDFS -L$path/lib"
  done < store-outs.txt
  info "nix store paths: $(wc -l < store-outs.txt | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# build_tools: Wine's build tools (makedep, winebuild, wrc, widl, wmc), built
# for the host so the thousands of runs during the build are not translated.
# They only run during the build and are not shipped.
# ---------------------------------------------------------------------------
build_tools() {
  local np="github:NixOS/nixpkgs/$NIXPKGS_REV" path pcp=""
  for path in $(nix_paths "$np#freetype.dev" "$np#freetype.out" "$np#libpng.dev" "$np#zlib.dev" \
    "$np#brotli.dev" "$np#bzip2.dev"); do
    [ -d "$path/lib/pkgconfig" ] && pcp="$path/lib/pkgconfig:$pcp"
  done
  rm -rf build-tools
  mkdir build-tools
  (
    cd build-tools
    export PATH="$NIX_TOOL_PATH$PATH" SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"
    export CC="${CCACHE:+$CCACHE }/usr/bin/clang" PKG_CONFIG_PATH="$pcp"
    # shellcheck disable=SC2086
    logged build-tools-configure "../$SRC/configure" --enable-archs=i386,x86_64 --without-gstreamer \
      --without-ffmpeg $WINE_WITHOUT --disable-tests
    logged build-tools-make make -j"$NCPU" __tooldeps__
    # wrc looks for nls/locale.nls next to its own tree, and __tooldeps__ does
    # not create it. A link to the file inside a real folder: a folder link
    # would land inside an existing nls/ as nls/nls.
    rm -rf nls
    mkdir nls
    ln -s "../../$SRC/nls/locale.nls" nls/locale.nls
    [ -r nls/locale.nls ] || die "build-tools/nls/locale.nls does not resolve"
  )
}

# ---------------------------------------------------------------------------
# build_sdl2: real SDL2 (nixpkgs' is sdl2-compat, which loads SDL3 from a path
# the bundling cannot see), for winebus's game-controller bus.
# ---------------------------------------------------------------------------
build_sdl2() {
  local tarball="$SDL_TEMP/SDL2-$SDL2_VERSION.tar.gz" src="$SDL_TEMP/SDL2-$SDL2_VERSION"
  local build="$SDL_TEMP/sdl2-build"
  fetch "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VERSION/SDL2-$SDL2_VERSION.tar.gz" \
    "$tarball" "$SDL2_SHA"
  rm -rf "$src" "$build" "$SDL2_PREFIX"
  tar -xzf "$tarball" -C "$SDL_TEMP"
  logged sdl2-configure cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$FLOOR" \
    -DCMAKE_INSTALL_PREFIX="$SDL2_PREFIX" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
  logged sdl2-build cmake --build "$build" --parallel
  logged sdl2-install cmake --install "$build"
  [ -f "$SDL2_PREFIX/lib/libSDL2-2.0.0.dylib" ] || die "the SDL2 build made no libSDL2-2.0.0.dylib"
  [ -f "$SDL2_PREFIX/include/SDL2/SDL.h" ] || die "the SDL2 build installed no headers"
  info "sdl2: $SDL2_VERSION $(lipo -archs "$SDL2_PREFIX/lib/libSDL2-2.0.0.dylib")"
}

# ---------------------------------------------------------------------------
# configure_wine: the engine itself: x86_64 unix half, i386 and x86_64 PE half.
# ---------------------------------------------------------------------------
configure_wine() {
  rm -rf build
  mkdir build
  (
    cd build
    export PATH="$WORK/ccache-bin:$NIX_TOOL_PATH$PATH" SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"
    export CC="${CCACHE:+$CCACHE }/usr/bin/clang -arch x86_64" CXX="${CCACHE:+$CCACHE }/usr/bin/clang++ -arch x86_64"
    export PKG_CONFIG_PATH="$NIX_PKG_CONFIG_PATH"
    # -Werror=unguarded-availability-new turns a call to an API above the floor
    # into an error instead of a weak link that is null on the floor's macOS.
    export CFLAGS="-O3 -Wno-error=implicit-function-declaration -Werror=unguarded-availability-new $NIX_INCS"
    export CROSSCFLAGS="-O3" LDFLAGS="$NIX_LDFS"
    # pipe2 is above the floor; Wine falls back to pipe and fcntl without it.
    export ac_cv_func_pipe2=no
    # Libraries Wine opens by name at run time, from the bundled lib folder.
    export ac_cv_lib_soname_freetype=libfreetype.6.dylib ac_cv_lib_soname_gnutls=libgnutls.30.dylib
    export ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib ac_cv_lib_soname_SDL2=libSDL2-2.0.0.dylib
    export SDL2_CFLAGS="-I$SDL2_PREFIX/include/SDL2"
    # shellcheck disable=SC2086
    if ! "../$SRC/configure" --host=x86_64-apple-darwin24 "--with-$MOD-tools=../build-tools" \
      --enable-archs=i386,x86_64 --disable-tests $WINE_WITHOUT --prefix="$PREFIX" \
      > "$LOGS/configure.log" 2>&1; then
      tail -n 40 "$LOGS/configure.log" >&2
      sed -n '100,400p' config.log >&2
      die "Wine's configure failed"
    fi
    # Configure only warns when an optional library is missing, and the soname
    # presets above silence even its FreeType error: check what it found.
    bash "$HERE/check-wine-config.sh" . > /dev/null || die "configure lost a library the engine needs (see above)"
  )
  info "$(bash "$HERE/check-wine-config.sh" build)"
}

# ---------------------------------------------------------------------------
# make_wine
# ---------------------------------------------------------------------------
make_wine() {
  (
    cd build
    export PATH="$WORK/ccache-bin:$NIX_TOOL_PATH$PATH"
    [ -z "$CCACHE" ] || ccache -z > /dev/null
    logged make make -j"$((NCPU + NCPU / 2))"
  )
  # An API the SDK declares but the floor lacks only warns; it must not ship.
  local above
  above=$(grep -oE "'[A-Za-z_0-9]+' has been marked as being introduced in macOS [0-9.]+" "$LOGS/make.log" \
    | sort -u || true)
  [ -z "$above" ] || die "the build uses APIs above macOS $FLOOR: $above"
  if [ -n "$CCACHE" ]; then
    info "ccache: $(ccache -s | tr '\n' ' ' | tr -s ' ')"
  fi
}

# ---------------------------------------------------------------------------
# fetch_payloads: wine-mono, wine-gecko, DXVK, DXMT and MoltenVK.
# ---------------------------------------------------------------------------
fetch_payloads() {
  local addons=$SRC/dlls/appwiz.cpl/addons.c mono gecko
  rm -rf downloads addons payload
  mkdir -p downloads payload
  fetch "$MOLTENVK_URL" downloads/moltenvk.tar "$MOLTENVK_SHA"
  tar -xf downloads/moltenvk.tar -C payload MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
  # Khronos ships it universal; the engine is x86_64 only.
  lipo -thin x86_64 payload/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib -output payload/libMoltenVK.dylib
  if [ "$RENAME" = 1 ]; then
    # MoltenVK's copy of the SPIR-V tool table names Wine as a generator
    # ("Wine", "Wine VKD3D Shader Compiler"): renamed in place, NUL-padded.
    # bundle_libraries signs the dylib again.
    "$WORK/venv/bin/python" "$HERE/rename_binaries.py" --protect "$HERE/rename-protect.txt" \
      --map "$HERE/rename-map.txt" --padded payload/libMoltenVK.dylib > "$LOGS/rename-moltenvk.log" 2>&1 \
      || { cat "$LOGS/rename-moltenvk.log" >&2; die "could not rename MoltenVK's strings"; }
    ! grep -aq Wine payload/libMoltenVK.dylib || die "libMoltenVK.dylib still says Wine"
    # Plan 3c-2 brings DXVK, DXMT and wine-mono back, rebuilt or renamed.
    info "payloads: MoltenVK $(lipo -archs payload/libMoltenVK.dylib), its Wine strings renamed"
    return
  fi
  mono=$(sed -n 's/^#define MONO_VERSION "\(.*\)"/\1/p' "$addons")
  gecko=$(sed -n 's/^#define GECKO_VERSION "\(.*\)"/\1/p' "$addons")
  [ "$mono" = "$MONO_VERSION" ] || die "Wine asks for wine-mono $mono, pinned is $MONO_VERSION"
  [ "$gecko" = "$GECKO_VERSION" ] || die "Wine asks for wine-gecko $gecko, pinned is $GECKO_VERSION"
  mkdir -p addons/mono addons/gecko
  fetch "https://dl.winehq.org/wine/wine-mono/$mono/wine-mono-$mono-x86.tar.xz" downloads/mono.tar.xz "$MONO_SHA"
  fetch "https://dl.winehq.org/wine/wine-gecko/$gecko/wine-gecko-$gecko-x86.tar.xz" \
    downloads/gecko-x86.tar.xz "$GECKO_X86_SHA"
  fetch "https://dl.winehq.org/wine/wine-gecko/$gecko/wine-gecko-$gecko-x86_64.tar.xz" \
    downloads/gecko-x86_64.tar.xz "$GECKO_X64_SHA"
  tar -xJf downloads/mono.tar.xz -C addons/mono
  tar -xJf downloads/gecko-x86.tar.xz -C addons/gecko
  tar -xJf downloads/gecko-x86_64.tar.xz -C addons/gecko
  [ -d "addons/mono/wine-mono-$mono" ] || die "the wine-mono tarball has an unexpected layout"
  [ -d "addons/gecko/wine-gecko-$gecko-x86_64" ] || die "the wine-gecko tarball has an unexpected layout"
  fetch "$DXVK_MAC_URL" downloads/dxvk-macos.tar.gz "$DXVK_MAC_SHA"
  fetch "$DXVK_UP_URL" downloads/dxvk.tar.gz "$DXVK_UP_SHA"
  fetch "$DXMT_URL" downloads/dxmt.tar.gz "$DXMT_SHA"
  tar -xzf downloads/dxvk-macos.tar.gz -C payload
  tar -xzf downloads/dxvk.tar.gz -C payload
  tar -xzf downloads/dxmt.tar.gz -C payload
  info "payloads: wine-mono $mono, wine-gecko $gecko, DXVK $DXVK_VERSION, DXMT $DXMT_VERSION," \
    "MoltenVK $(lipo -archs payload/libMoltenVK.dylib)"
}

# install_ano_layout (5.x): bin/ano-loader and bin/ano-server only; the loader
# itself is lib/ano/x86_64-unix/ano-core, the name ntdll starts it by
# (patches/rename/0001). No man pages or desktop files: they are for a Linux
# install, not the app.
install_ano_layout() {
  local unix=$TOP/lib/$MOD/x86_64-unix
  rm -rf "$TOP/share/man" "$TOP/share/applications"
  find "$TOP/lib/$MOD"/*-windows -name '*.a' -delete
  find "$TOP/lib/$MOD"/*-windows -type f -print0 \
    | xargs -0 -P "$NCPU" -n 64 x86_64-w64-mingw32-strip --strip-debug 2> /dev/null || true
  [ -x "$unix/ano" ] || die "no loader at $unix/ano"
  mv "$unix/ano" "$unix/$LOADER"
  rm -f "$TOP/bin/ano"
  ln -s "../lib/$MOD/x86_64-unix/$LOADER" "$TOP/bin/ano-loader"
  [ -x "$TOP/bin/$SERVER" ] || die "no $SERVER in $TOP/bin"
  # The LGPL notice. Its only "wine" words are the license phrase and the repo
  # URL, both on the gate's allowlist.
  cat > "$TOP/share/$MOD/NOTICES" << EOF
Ano engine $VERSION

This engine is a modified copy of software by the Wine project authors,
with CrossOver's macOS changes. It is distributed under the GNU Lesser
General Public License, version 2.1 or (at your option) any later version.
Ano renamed its files, programs and settings and changed how it is built.

The source of this engine and the scripts that build it:
https://github.com/HighStormPVP/AnoWine
EOF
  info "bin: $(ls "$TOP/bin" | tr '\n' ' ')"
  info "ano-loader --version: $("$TOP/bin/ano-loader" --version)"
}

# ---------------------------------------------------------------------------
# install_tree: lay out Libraries/ the way the app expects it.
# ---------------------------------------------------------------------------
install_tree() {
  local staging="$WORK/staging" root=$PREFIX dxmt="payload/v$DXMT_VERSION"
  local dxvk="payload/dxvk-macOS-async-v$DXVK_VERSION-20230507-repack" arch dll file loader name
  rm -rf staging Libraries
  # install-lib: what programs need at run time, without the import libraries.
  (
    cd build
    export PATH="$NIX_TOOL_PATH$PATH"
    logged install make -j"$NCPU" install-lib DESTDIR="$staging"
  )
  mkdir -p "$TOP"
  cp -R "$staging$root/bin" "$TOP/bin"
  cp -R "$staging$root/lib" "$TOP/lib"
  cp -R "$staging$root/share" "$TOP/share"
  if [ "$RENAME" = 1 ]; then
    install_ano_layout
    return
  fi
  mkdir -p Libraries/Wine/share/wine/mono Libraries/Wine/share/wine/gecko
  cp -R addons/mono/* Libraries/Wine/share/wine/mono/
  cp -R addons/gecko/* Libraries/Wine/share/wine/gecko/

  # DXMT's Wine half is only the winemetal bridge. Its d3d11, dxgi and
  # d3d10core stay out of the builtins (they would take over every new bottle)
  # and go to the per-bottle payload instead, like DXVK.
  cp -R "$dxmt/x86_64-unix/." Libraries/Wine/lib/wine/x86_64-unix/
  cp "$dxmt/x86_64-windows/winemetal.dll" Libraries/Wine/lib/wine/x86_64-windows/
  [ ! -f "$dxmt/i386-windows/winemetal.dll" ] || cp "$dxmt/i386-windows/winemetal.dll" Libraries/Wine/lib/wine/i386-windows/
  mkdir -p Libraries/DXVK Libraries/DXMT
  cp -R "$dxvk/." Libraries/DXVK/
  # The macOS repack has no dxgi; 32-bit bottles need upstream DXVK's.
  cp "payload/dxvk-$DXVK_VERSION/x32/dxgi.dll" Libraries/DXVK/x32/dxgi.dll
  cp -R "$dxmt/x86_64-windows" Libraries/DXMT/x64
  cp -R "$dxmt/i386-windows" Libraries/DXMT/x32
  # The app treats a DLL marked "Wine builtin DLL" at 0x40 as not native and
  # skips it; DXMT's three front ends carry that mark, so give them the
  # ordinary DOS stub there.
  for arch in x64 x32; do
    for dll in d3d11 d3d10core dxgi; do
      file="Libraries/DXMT/$arch/$dll.dll"
      [ -f "$file" ] || continue
      printf '\016\037\272\016\000\264\011\315\041\270\001\114\315\041\220\220' \
        | dd of="$file" bs=1 seek=64 conv=notrunc status=none
      if dd if="$file" bs=1 skip=64 count=16 status=none | grep -aq 'Wine builtin'; then
        die "$file still carries the builtin mark"
      fi
    done
  done

  # Import libraries are for linking only, and gcc leaves DWARF in every DLL
  # (ntdll.dll would be 3 MB instead of 0.7 MB).
  find Libraries/Wine/lib/wine/*-windows -name '*.a' -delete
  find Libraries/Wine/lib/wine/*-windows -type f -print0 \
    | xargs -0 -P "$NCPU" -n 64 x86_64-w64-mingw32-strip --strip-debug 2> /dev/null || true

  # Wine 11 keeps its loader next to ntdll.so and finds ntdll.so from its own
  # real path, so bin/ gets links, not copies. The app runs bin/wine64.
  loader=Libraries/Wine/lib/wine/x86_64-unix/wine
  [ -x "$loader" ] || die "no loader at $loader"
  for name in wine wine64 wineloader; do
    ln -sf ../lib/wine/x86_64-unix/wine "Libraries/Wine/bin/$name"
  done
  info "wine64 --version: $(Libraries/Wine/bin/wine64 --version)"
}

# scan <file>: the /nix/store libraries a Mach-O file links.
scan() { otool -L "$1" 2> /dev/null | awk '/\/nix\/store/ {print $1}' || true; }

# imports_iconv <file>: the file calls macOS's iconv (_iconv), not GNU's (_libiconv).
imports_iconv() {
  local undefined
  undefined=$(nm -u "$1" 2> /dev/null || true)
  grep -qE '^ *_iconv$' <<< "$undefined"
}

# relink <file>: point a Mach-O file's own id and its /nix/store dependencies
# at the bundled copies, relative to itself, and sign it again.
relink() {
  local file=$1 libdir="$WORK/$TOP/lib" rel ref
  rel=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], os.path.dirname(os.path.abspath(sys.argv[2]))))' \
    "$libdir" "$file")
  chmod u+w "$file" 2> /dev/null || true
  case "$file" in
    *.dylib*) install_name_tool -id "@loader_path/$(basename "$file")" "$file" 2> /dev/null || true ;;
  esac
  for ref in $(scan "$file"); do
    if [[ "$(basename "$ref")" == libiconv*.dylib ]] && imports_iconv "$file"; then
      install_name_tool -change "$ref" /usr/lib/libiconv.2.dylib "$file" 2> /dev/null || true
    else
      install_name_tool -change "$ref" "@loader_path/$rel/$(basename "$ref")" "$file" 2> /dev/null || true
    fi
  done
  codesign -f -s - "$file" 2> /dev/null || true
}

# ---------------------------------------------------------------------------
# bundle_libraries: copy every library the engine needs from /nix/store into
# <top>/lib and make the tree relocatable.
# ---------------------------------------------------------------------------
bundle_libraries() {
  local libdir="$WORK/$TOP/lib" path plugin so file queue next lib base
  # GStreamer's plugins are loaded from a folder, so they are copied first and
  # their own dependencies (the codecs) are found through them.
  mkdir -p "$libdir/gstreamer-1.0"
  while read -r path; do
    for plugin in "$path/lib/gstreamer-1.0/"*.dylib; do
      [ -f "$plugin" ] || continue
      cp -L "$plugin" "$libdir/gstreamer-1.0/"
      chmod u+w "$libdir/gstreamer-1.0/$(basename "$plugin")"
    done
  done < store-outs.txt
  cp payload/libMoltenVK.dylib "$libdir/libMoltenVK.dylib"
  cp "$SDL2_PREFIX/lib/libSDL2-2.0.0.dylib" "$libdir/libSDL2-2.0.0.dylib"
  chmod u+w "$libdir/libMoltenVK.dylib" "$libdir/libSDL2-2.0.0.dylib"

  # The closure: freetype and gnutls are opened by name at run time and appear
  # in no load command, so they are named; everything else is found by
  # following load commands from the Wine modules, the loader and the plugins.
  queue=""
  while read -r path; do
    for so in libfreetype.6.dylib libgnutls.30.dylib; do
      [ ! -f "$path/lib/$so" ] || queue="$queue $path/lib/$so"
    done
  done < store-outs.txt
  for file in "$TOP/lib/$MOD"/*-unix/*.so "$TOP/lib/$MOD/x86_64-unix/$LOADER" "$libdir"/gstreamer-1.0/*.dylib; do
    [ -f "$file" ] || continue
    queue="$queue $(scan "$file" | tr '\n' ' ')"
  done
  while [ -n "$queue" ]; do
    next=""
    for lib in $queue; do
      base=$(basename "$lib")
      [ ! -e "$libdir/$base" ] || continue
      cp -L "$lib" "$libdir/$base"
      chmod u+w "$libdir/$base"
      next="$next $(scan "$libdir/$base" | tr '\n' ' ')"
    done
    queue=""
    for lib in $next; do
      [ -e "$libdir/$(basename "$lib")" ] || queue="$queue $lib"
    done
  done

  for file in "$libdir"/*.dylib* "$libdir"/gstreamer-1.0/*.dylib*; do
    [ ! -f "$file" ] || relink "$file"
  done
  while read -r file; do relink "$file"; done < <(find "$TOP/bin" -type f)
  while read -r file; do relink "$file"; done < <(find "$TOP/lib/$MOD" -name '*.so')
  ln -sf libfreetype.6.dylib "$libdir/libfreetype.dylib"
  ln -sf libSDL2-2.0.0.dylib "$libdir/libSDL2.dylib"
  # The Wine modules open gnutls, freetype and MoltenVK by bare name, which
  # dlopen looks up on the caller's rpaths: two folders up is lib/.
  for file in "$TOP/lib/$MOD"/*-unix/*.so; do
    install_name_tool -add_rpath "@loader_path/../../" "$file" 2> /dev/null || true
    codesign -f -s - "$file" 2> /dev/null || true
  done
  info "bundled: $(find "$libdir" -maxdepth 1 -name '*.dylib*' | wc -l | tr -d ' ') libraries," \
    "$(find "$libdir/gstreamer-1.0" -mindepth 1 | wc -l | tr -d ' ') gstreamer plugins"
}

# mark_builtin <dll>: write the builtin mark the engine checks at 0x40.
mark_builtin() {
  python3 - "$1" "$BUILTIN" << 'PY'
import struct, sys
path, mark = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, "rb").read())
if struct.unpack_from("<I", data, 0x3C)[0] < 0x60:
    sys.exit(f"{path}: the PE header starts inside the 32 bytes at 0x40")
data[0x40:0x60] = mark + bytes(32 - len(mark))
open(path, "wb").write(bytes(data))
PY
}

# ---------------------------------------------------------------------------
# build_shims: upstream's two D3DMetal helpers. The app swaps them in when the
# Game Porting Toolkit is imported (d3d12 video processing, DXGI driver version).
# ---------------------------------------------------------------------------
build_shims() {
  local dest=$TOP/lib/gptk-video src=recipe/gptk-video
  mkdir -p "$dest"
  x86_64-w64-mingw32-gcc -shared -O2 -fno-strict-aliasing -o "$dest/d3d12shim.dll" \
    "$WORK/$src/d3d12shim.c" "$WORK/$src/d3d12shim.def" -I"$WORK/$src" -luuid -ldxguid
  mark_builtin "$dest/d3d12shim.dll"
  x86_64-w64-mingw32-gcc -shared -O2 -fno-strict-aliasing -o "$dest/dxgishim.dll" \
    "$WORK/$src/dxgishim.c" "$WORK/$src/dxgishim.def" -luuid -ldxguid
  mark_builtin "$dest/dxgishim.dll"
  # tar keeps no empty folders, and the app's importer needs this one.
  mkdir -p "$TOP/lib/external"
  cat > "$TOP/lib/external/README" << EOF
This folder is for Apple's Game Porting Toolkit (D3DMetal.framework and
libd3dshared.dylib). Apple does not allow it to be redistributed, so it is
not shipped here. When you import the toolkit in Ano's settings, Ano puts
both here and makes d3d10.so, d3d11.so, d3d12.so and dxgi.so in
lib/$MOD/x86_64-unix symbolic links to ../../external/libd3dshared.dylib.

Keep them links: libd3dshared.dylib finds D3DMetal.framework through its
only rpath, @loader_path, so a copy anywhere else cannot load it.
EOF
}

# ---------------------------------------------------------------------------
# write_version: the version plist, laid out as upstream's WhiskyWineVersion.plist.
# ---------------------------------------------------------------------------
write_version() {
  local major=${VERSION%%.*} minor patch=${VERSION##*.}
  minor=${VERSION#*.}
  minor=${minor%%.*}
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' \
    '<dict>' \
    '  <key>gptkCapable</key>' \
    '  <true/>' \
    '  <key>dxvkVersion</key>' \
    "  <string>$DXVK_VERSION</string>" \
    '  <key>dxmtVersion</key>' \
    "  <string>$DXMT_VERSION</string>" \
    '  <key>version</key>' \
    '  <dict>' \
    '    <key>major</key>' \
    "    <integer>$major</integer>" \
    '    <key>minor</key>' \
    "    <integer>$minor</integer>" \
    '    <key>patch</key>' \
    "    <integer>$patch</integer>" \
    '  </dict>' \
    '</dict>' \
    '</plist>' > "Libraries/$PLIST"
  info "version: $VERSION"
}

# ---------------------------------------------------------------------------
# verify_tree: refuse a tree that would not work on someone else's Mac.
# ---------------------------------------------------------------------------
verify_tree() {
  local w=$TOP lib count deps dll
  # Every Mach-O file: no absolute paths outside the system, nothing above the
  # floor, and every undefined symbol defined by the SDK or the bundle.
  python3 - Libraries "$(xcrun --sdk macosx --show-sdk-path)" "${FLOOR%%.*}" << 'PY'
import json, os, re, subprocess, sys

root, sdk, floor = sys.argv[1], sys.argv[2], int(sys.argv[3])
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}

def tool(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout

def system_path(path):
    return not path.startswith("/") or path.startswith(("/usr/lib/", "/System/"))

machos = []
for folder, _, names in os.walk(root):
    for name in names:
        path = os.path.join(folder, name)
        if not os.path.islink(path):
            with open(path, "rb") as fh:
                if fh.read(4) in MAGICS:
                    machos.append(path)

# What the SDK offers: the symbol lists of its .tbd stubs (YAML v4 or JSON v5).
offered = set()
LISTS = re.compile(r"(weak-symbols|thread-local-symbols|symbols|objc-classes|objc-eh-types|objc-ivars)"
                   r":\s*\[([^\]]*)\]", re.S)
PREFIX = {"objc-classes": ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"), "objc-eh-types": ("_OBJC_EHTYPE_$_",),
          "objc-ivars": ("_OBJC_IVAR_$_",), "objc_class": ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"),
          "objc_eh_type": ("_OBJC_EHTYPE_$_",), "objc_ivar": ("_OBJC_IVAR_$_",)}

def add(kind, name):
    name = name.strip().strip("'\"")
    if name:
        for prefix in PREFIX.get(kind, ("",)):
            offered.add(prefix + name)

def walk_json(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("global", "weak", "thread_local", "objc_class", "objc_eh_type", "objc_ivar") \
                    and isinstance(value, list):
                for name in value:
                    if isinstance(name, str):
                        add(key, name)
            else:
                walk_json(value)
    elif isinstance(node, list):
        for item in node:
            walk_json(item)

for folder, _, names in os.walk(sdk):
    for name in names:
        if name.endswith(".tbd"):
            text = open(os.path.join(folder, name), errors="ignore").read()
            if text.lstrip().startswith("{"):
                try:
                    walk_json(json.loads(text))
                except ValueError:
                    pass
            else:
                for kind, body in LISTS.findall(text):
                    for item in body.split(","):
                        add(kind, item)

problems = []
undefined = {}
for path in machos:
    lines = [line.strip() for line in tool("otool", "-D", path).splitlines()[1:]]
    for own_id in lines:
        if own_id and not own_id.endswith(":") and not system_path(own_id):
            problems.append(f"{path}: id {own_id} is an absolute path")
    for line in tool("otool", "-L", path).splitlines():
        if line.startswith(("\t", " ")):
            dep = line.split()[0]
            if not system_path(dep):
                problems.append(f"{path}: links {dep}")
    load = tool("otool", "-l", path).splitlines()
    for i, line in enumerate(load):
        if line.split()[:2] == ["cmd", "LC_BUILD_VERSION"]:
            for following in load[i + 1:i + 6]:
                words = following.split()
                if words[:1] == ["minos"] and int(words[1].split(".")[0]) > floor:
                    problems.append(f"{path}: minos {words[1]} is above macOS {floor}")
    for line in tool("nm", "-gUj", path).splitlines():
        if line.strip() and not line.rstrip().endswith(":"):
            offered.add(line.strip())
    for line in tool("nm", "-m", path).splitlines():
        match = re.search(r"\(undefined\) (weak )?external (\S+)", line)
        if match:
            undefined.setdefault(path, set()).add((match.group(2), "weak" if match.group(1) else "strong"))

for path, symbols in sorted(undefined.items()):
    for symbol, kind in sorted(symbols):
        if symbol not in offered:
            problems.append(f"{path}: needs {symbol} ({kind}), in neither the SDK nor the bundle")

for problem in problems:
    print(f"::error::{problem}")
print(f"{len(machos)} Mach-O files checked, {len(offered)} symbols offered, {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
PY
  local m="$w/lib/$MOD"
  count=$(find "$m/i386-windows" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  [ "$count" -gt 500 ] || die "i386-windows has only $count files; 32-bit programs could not start"
  count=$(wc -c < "$m/x86_64-windows/ntdll.dll" | tr -d ' ')
  [ "$count" -lt 1500000 ] || die "ntdll.dll is $count bytes: the Windows half was not stripped"
  if [ "$RENAME" = 0 ]; then
    for lib in "$w"/share/wine/mono/wine-mono-* "$w"/share/wine/gecko/wine-gecko-*-x86 \
      "$w"/share/wine/gecko/wine-gecko-*-x86_64; do
      [ -d "$lib" ] || die "missing $lib (a new bottle would stop on an install dialog)"
    done
    [ -f Libraries/DXVK/x64/d3d11.dll ] || die "no DXVK payload"
    [ -f Libraries/DXVK/x32/dxgi.dll ] || die "no 32-bit DXVK dxgi"
    [ -f "$m/x86_64-unix/winemetal.so" ] || die "no DXMT winemetal bridge"
  fi
  [ -d "$w/lib/external" ] || die "no lib/external for the Game Porting Toolkit"
  for dll in d3d11 dxgi d3d10core; do
    ! grep -aqE 'DXMT_|dxmt\.con' "$m/x86_64-windows/$dll.dll" \
      || die "the builtin $dll.dll is DXMT's, not the engine's"
  done
  [ ! -f "$m/x86_64-windows/nvapi64.dll" ] || die "nvapi64.dll must not be a builtin"
  deps=$(otool -L "$m/x86_64-unix/${MOD}dmo.so")
  grep -q libavcodec <<< "$deps" || die "${MOD}dmo.so does not link ffmpeg: no video decoding"
  deps=$(otool -L "$m/x86_64-unix/${MOD}gstreamer.so")
  grep -q libgstreamer-1.0 <<< "$deps" || die "${MOD}gstreamer.so does not link gstreamer"
  count=$(find "$w/lib/gstreamer-1.0" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  [ "$count" -gt 50 ] || die "only $count gstreamer plugins"
  ! grep -aq 'SDL support not compiled in' "$m/x86_64-unix/${MOD}bus.so" \
    || die "${MOD}bus.so has no SDL bus: no game controllers"
  [ -f "$w/lib/libSDL2-2.0.0.dylib" ] || die "libSDL2-2.0.0.dylib is not bundled"
  [ "$RENAME" = 0 ] || verify_no_wine
  info "verify: relocatable, floor $FLOOR, symbols resolved, payloads present"
}

# verify_no_wine (5.x): the loader's own name for itself, no "wine" in any
# path, and none in the signing identifier of any Mach-O file.
verify_no_wine() {
  local version paths file id ids=""
  version=$("$TOP/bin/ano-loader" --version)
  [[ "$version" == ano-11.19* ]] || die "ano-loader --version says '$version', not ano-11.19"
  paths=$(find Libraries | grep -i wine || true)
  [ -z "$paths" ] || die "paths with wine: $(head -n 20 <<< "$paths" | tr '\n' ' ')"
  while read -r file; do
    id=$(codesign -dv "$file" 2>&1 | sed -n 's/^Identifier=//p' || true)  # unsigned: no identifier
    if grep -qi wine <<< "$id"; then ids="$ids $file ($id)"; fi
  done < <(find "$TOP/bin" "$TOP/lib" -type f ! -path '*-windows/*')
  [ -z "$ids" ] || die "signing identifiers with wine:$ids"
  info "verify: $version; no path or signing identifier with wine"
}

# ---------------------------------------------------------------------------
# smoke_test: run the built engine.
# ---------------------------------------------------------------------------
smoke_test() {
  (
    local s="$WORK/smoke" w="$WORK/$TOP" t="$WORK/recipe/tests" results
    local run="$w/bin/wine64" boot=wineboot pfx=WINE diag=winediag
    [ "$RENAME" = 0 ] || { run="$w/bin/ano-loader" boot=ano-boot pfx=ANO diag=anodiag; }
    rm -rf "$s"
    mkdir -p "$s"
    export PATH="$NIX_TOOL_PATH$PATH"
    x86_64-w64-mingw32-gcc -O2 -o "$s/winmsg.exe" "$t/winmsg.c" -luser32
    x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$s/flsgetvalue2.exe" "$t/flsgetvalue2.c"
    x86_64-w64-mingw32-gcc -O2 -o "$s/mfprobe.exe" "$t/mfprobe.c" -lmfplat -lole32
    clang -arch x86_64 -O2 -o "$s/dlopenall" "$t/dlopenall.c"
    export "${pfx}PREFIX=$s/prefix" DYLD_FALLBACK_LIBRARY_PATH="$w/lib" "${pfx}DLLOVERRIDES=mscoree=d;mshtml=d"
    env "${pfx}DEBUG=-all" "$run" "$boot" -u > "$LOGS/smoke-boot.log" 2>&1 || true

    # A display driver that fails to start falls back to "nodrv" silently;
    # only creating a window shows it.
    env "${pfx}DEBUG=+$diag" "$run" "$s/winmsg.exe" > "$LOGS/smoke-winmsg.log" 2>&1 || true
    grep -E '^\[|^RESULT|^FAIL' "$LOGS/smoke-winmsg.log" || true
    ! grep -q nodrv_CreateWindow "$LOGS/smoke-winmsg.log" || die "the display driver did not load (nodrv)"
    grep -q 'RESULT: windows ok' "$LOGS/smoke-winmsg.log" || die "the engine cannot create a window"

    env "${pfx}DEBUG=-all" MVK_CONFIG_LOG_LEVEL=0 "$run" "$s/flsgetvalue2.exe" > "$LOGS/smoke-fls.log" 2>&1 \
      || { cat "$LOGS/smoke-fls.log"; die "flsgetvalue2.exe failed"; }

    # Media Foundation answers even with no GStreamer plugins found; ask for a decoder.
    env "${pfx}DEBUG=-all" "$run" "$s/mfprobe.exe" > "$LOGS/smoke-mf.log" 2>&1 || true
    grep -E '^\[|^RESULT|^FAIL' "$LOGS/smoke-mf.log" || true
    grep -q 'RESULT: media foundation has decoders' "$LOGS/smoke-mf.log" \
      || die "Media Foundation has no H.264 decoder: GStreamer found no plugins"

    # Load every bundled library by path (on the builder the /nix/store
    # originals would hide a broken copy).
    find "$w/lib" \( -name '*.dylib*' -o -name '*.so' \) | sort | tr '\n' '\0' \
      | xargs -0 "$s/dlopenall" > "$LOGS/smoke-dlopen.log" 2>&1 || true
    grep '^FAIL' "$LOGS/smoke-dlopen.log" | head -20 || true
    results=$(grep '^RESULT' "$LOGS/smoke-dlopen.log" || true)
    echo "$results"
    [ -n "$results" ] && ! grep -q '^FAIL' "$LOGS/smoke-dlopen.log" && ! grep -qv '^RESULT: 0 of' <<< "$results" \
      || die "bundled libraries do not load"
    "$w/bin/$SERVER" -k 2> /dev/null || true
  )
  info "smoke tests: window, fibers, media foundation, every bundled library loads"
}

# ---------------------------------------------------------------------------
# package
# ---------------------------------------------------------------------------
package() {
  rm -f "$OUT/Libraries.tar.gz" "$OUT/Libraries.tar.gz.sha256"
  tar -czf "$OUT/Libraries.tar.gz" Libraries
  (cd "$OUT" && shasum -a 256 Libraries.tar.gz > Libraries.tar.gz.sha256)
  cp "Libraries/$PLIST" "$OUT/$PLIST"
  info "tarball: $(wc -c < "$OUT/Libraries.tar.gz" | tr -d ' ') bytes, sha256 $(cut -d' ' -f1 < "$OUT/Libraries.tar.gz.sha256")"
}

PHASES="check_host fetch_sources apply_patches rename_sources nix_inputs build_tools build_sdl2 configure_wine make_wine
  fetch_payloads install_tree bundle_libraries build_shims write_version verify_tree smoke_test package"

total=$SECONDS
for phase in $PHASES; do
  cd "$WORK"
  echo "== $phase"
  started=$SECONDS
  "$phase"
  info "phase $phase: $((SECONDS - started))s"
done
info "total: $((SECONDS - total))s"
cp "$INFO" "$OUT/build-info.txt"
