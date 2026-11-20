#!/bin/bash
# check-graphics.sh <Libraries/Ano> <Libraries> <bottle> (Plan 3c-2): every DXVK
# and DXMT DLL the engine ships loads in the bottle as itself (not the builtin
# of the same name). tests/graphics/loadtest.c prints LOADED or FAIL per DLL
# and CREATE <hr> for D3D11CreateDevice, which is reported, not required: a CI
# runner promises no GPU. One process per folder, so two d3d11.dll never meet.
set -euo pipefail
ENGINE=$1
LIBS=$2
BOTTLE=$3
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)

x86_64-w64-mingw32-gcc -O2 -o "$WORK/loadtest64.exe" "$HERE/tests/graphics/loadtest.c"
i686-w64-mingw32-gcc -O2 -o "$WORK/loadtest32.exe" "$HERE/tests/graphics/loadtest.c"

# Native first, as the app sets them for a bottle; the engine's dxgi stays the
# fallback (64-bit DXVK ships none). ano-dbg is off: a crash dialog would wait.
export ANOPREFIX=$BOTTLE DYLD_FALLBACK_LIBRARY_PATH=$ENGINE/lib ANODEBUG=warn+module
export ANODLLOVERRIDES="d3d11,d3d10core,nvapi64,nvngx=n;dxgi=n,b;ano-dbg.exe=d;mscoree,mshtml=d"

zpath() {  # the bottle's Z: path of a Mac path
  local mac
  mac="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  printf 'Z:%s' "${mac//\//\\}"
}

fail=0
run() {  # run <exe> <folder under Libraries> <dll>...
  local exe=$1 dir=$2 dll code=0
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
  grep -E '^(LOADED|FAIL|CREATE)|err:|warn:module' "$WORK/out.txt" || true
  if [ "$code" != 0 ]; then
    echo "FAIL $exe in $dir: exit $code$([ "$code" != 142 ] || echo ' (stopped after 180 s)')"
    fail=1
  fi
}

run loadtest64.exe DXVK/x64 d3d10core.dll d3d11.dll
run loadtest64.exe DXMT/x64 d3d10core.dll d3d11.dll dxgi.dll nvapi64.dll nvngx.dll
run loadtest32.exe DXVK/x32 d3d10core.dll d3d11.dll dxgi.dll
run loadtest32.exe DXMT/x32 d3d10core.dll d3d11.dll dxgi.dll
exit $fail
