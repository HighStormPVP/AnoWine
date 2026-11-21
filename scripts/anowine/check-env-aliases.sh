#!/bin/bash
# check-env-aliases.sh <Libraries/Ano> <bottle>: Plan 3c-4a, Task 6. Apple's
# D3DMetal reads WINED3DMETAL and WINEESYNC itself. Ano sets ANOD3DMETAL and
# ANOESYNC; the engine copies them to the old names inside each process only
# (patches/rename/0005). Passes when the Mac half of the D3DMetal stand-in
# (tests/aliases, loaded as Apple's libd3dshared.dylib is) reads both old
# names, the Windows environment has neither, and no engine process shows
# either in its environment (ps -E): the program, its child and the server.
set -euo pipefail
ENGINE=$1
BOTTLE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/tests/aliases
WORK=$(mktemp -d)
PE=$ENGINE/lib/ano/x86_64-windows
UNIX=$ENGINE/lib/ano/x86_64-unix
fails=0
fail() { echo "::error::D3DMetal's variables: $*"; fails=$((fails + 1)); }

x86_64-w64-mingw32-dlltool -d "$SRC/ntdll-aliases.def" -l "$WORK/libntdll-aliases.a"
x86_64-w64-mingw32-gcc -shared -O2 -o "$WORK/aliastest.dll" "$SRC/aliastest.c" "$WORK/libntdll-aliases.a"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/envrun.exe" "$SRC/envrun.c"
clang -arch x86_64 -dynamiclib -O2 -o "$WORK/aliastest.so" "$SRC/aliastest_unix.c"
python3 - "$WORK/aliastest.dll" << 'PY'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
if struct.unpack_from("<I", data, 0x3C)[0] < 0x60:
    sys.exit(f"{path}: the PE header starts inside the 32 bytes at 0x40")
data[0x40:0x60] = b"Wine builtin DLL" + bytes(16)
open(path, "wb").write(bytes(data))
PY
cp "$WORK/aliastest.dll" "$PE/"
cp "$WORK/aliastest.so" "$UNIX/"

export ANOPREFIX=$BOTTLE DYLD_FALLBACK_LIBRARY_PATH=$ENGINE/lib ANODEBUG=-all
export ANODLLOVERRIDES="mscoree=d;mshtml=d;ano-dbg.exe=d"
"$ENGINE/bin/ano-server" -k 2> /dev/null || true
ANOD3DMETAL=1 ANOESYNC=1 perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 180 \
  "$ENGINE/bin/ano-loader" "$WORK/envrun.exe" > "$WORK/out.txt" 2>&1 &
run=$!
# While the child pings, every engine process's environment as ps -E shows it.
seen=0
for _ in $(seq 1 120); do
  ps -E -ww -axo pid=,command= | grep -F "$ENGINE" | grep -v grep > "$WORK/ps.txt" || true
  if grep -qi "ping" "$WORK/ps.txt"; then seen=1; break; fi
  kill -0 "$run" 2> /dev/null || break
  sleep 1
done
code=0
wait "$run" || code=$?
"$ENGINE/bin/ano-server" -k 2> /dev/null || true
# The stand-in leaves the engine, or bottles made later get it as a builtin.
rm -f "$PE/aliastest.dll" "$UNIX/aliastest.so"
# A Windows program ends its lines with \r\n.
tr -d '\r' < "$WORK/out.txt" > "$WORK/out.lf"
cat "$WORK/out.lf"
echo "engine processes seen with ps -E: $(wc -l < "$WORK/ps.txt")"

[ "$code" = 0 ] || fail "envrun.exe exited $code"
[ "$seen" = 1 ] || fail "the child (ping) was never seen running"
# Positive control: ps -E shows the environment the program was started with.
grep -q "ANOD3DMETAL=1" "$WORK/ps.txt" || fail "ps -E shows no ANOD3DMETAL=1, so the environment cannot be checked"
if grep -E "WINED3DMETAL=|WINEESYNC=" "$WORK/ps.txt" | cut -c1-300; then
  fail "an engine process shows WINED3DMETAL or WINEESYNC in its environment"
fi
grep -qx "unix: WINED3DMETAL=1 WINEESYNC=1 (call 0)" "$WORK/out.lf" \
  || fail "inside the process, the old names are not set (what D3DMetal would read)"
grep -qx "windows: WINED3DMETAL=- WINEESYNC=-" "$WORK/out.lf" \
  || fail "the Windows environment shows an old name"
grep -qx "child: done" "$WORK/out.lf" || fail "the child did not finish"

[ "$fails" -eq 0 ] || exit 1
echo "D3DMetal's variables: set inside the process only"
