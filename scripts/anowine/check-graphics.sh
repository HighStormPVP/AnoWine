#!/bin/bash
# check-graphics.sh <Libraries/Ano> <Libraries> <bottle> (Plan 3c-2): every DXVK
# and DXMT DLL the engine ships loads in the bottle as itself (not the builtin
# of the same name). tests/graphics/loadtest.c loads them all, then creates a
# D3D11 device with each d3d11.dll; it prints LOADED or FAIL per DLL and CREATE
# <hr> (or CRASH) per device. Only loading decides: a CI runner promises no GPU,
# so devices are reported, and a crash while creating one is a warning. One
# process per folder, so two d3d11.dll never meet.
# ANO_GRAPHICS_SETS picks the sets (default "DXVK DXMT"); the check job runs
# it on the prebuilt DXVK runtime 4.9.0 shipped too, for comparison.
set -euo pipefail
ENGINE=$1
LIBS=$2
BOTTLE=$3
SETS=${ANO_GRAPHICS_SETS:-DXVK DXMT}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)

x86_64-w64-mingw32-gcc -O2 -o "$WORK/loadtest64.exe" "$HERE/tests/graphics/loadtest.c"
i686-w64-mingw32-gcc -O2 -o "$WORK/loadtest32.exe" "$HERE/tests/graphics/loadtest.c"

# Native first, as the app sets them for a bottle; the engine's dxgi stays the
# fallback (64-bit DXVK ships none). ano-dbg is off: a crash dialog would wait.
export ANOPREFIX=$BOTTLE DYLD_FALLBACK_LIBRARY_PATH=$ENGINE/lib ANODEBUG=warn+module
export ANODLLOVERRIDES="d3d11,d3d10core=n;dxgi=n,b;ano-dbg.exe=d;mscoree,mshtml=d"

zpath() {  # the bottle's Z: path of a Mac path
  local mac
  mac="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  printf 'Z:%s' "${mac//\//\\}"
}

fail=0
run() {  # run <exe> <folder under Libraries> <dll>...
  local exe=$1 dir=$2 dll path code=0
  local args=()
  shift 2
  for dll in "$@"; do
    if [ -f "$LIBS/$dir/$dll" ]; then
      args+=("$(zpath "$LIBS/$dir/$dll")")
    else
      echo "FAIL $dir/$dll (missing)"
      fail=1
    fi
  done
  [ ${#args[@]} -gt 0 ] || return 0
  # Output to a file: processes the run starts may keep a pipe open.
  perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 180 "$ENGINE/bin/ano-loader" "$WORK/$exe" "${args[@]}" \
    > "$WORK/out.txt" 2>&1 || code=$?
  "$ENGINE/bin/ano-server" -k 2> /dev/null || true
  grep -E '^(LOADED|FAIL|CREATE|CRASH) |err:|warn:module:import' "$WORK/out.txt" || true
  for path in "${args[@]}"; do
    grep -qxF "LOADED $path" <(tr -d '\r' < "$WORK/out.txt") || { echo "FAIL $path (no LOADED line)"; fail=1; }
  done
  if [ "$code" != 0 ]; then
    echo "::warning::$exe in $dir: exit $code$([ "$code" != 142 ] || echo ' (stopped after 180 s)') after loading"
  fi
}

for set in $SETS; do
  case $set in
    DXVK)
      run loadtest64.exe DXVK/x64 d3d10core.dll d3d11.dll
      run loadtest32.exe DXVK/x32 d3d10core.dll d3d11.dll dxgi.dll ;;
    DXMT)
      # The app puts DXMT's front ends in a bottle, never its nvapi64 or nvngx
      # (they keep DXMT's builtin mark, as in runtime 4.9.0, and stay unused).
      run loadtest64.exe DXMT/x64 d3d10core.dll d3d11.dll dxgi.dll
      run loadtest32.exe DXMT/x32 d3d10core.dll d3d11.dll dxgi.dll ;;
    *) echo "FAIL unknown set $set"; fail=1 ;;
  esac
done
exit $fail
