#!/bin/bash
# check-aliases.sh <Libraries/Ano> <bottle>: the engine keeps the hidden
# aliases closed parts need (scripts/anowine/aliases.txt). A stand-in for
# Apple's D3DMetal (tests/aliases): a DLL marked "Wine builtin DLL" that
# imports ntdll's old names, with a Mac half that exports only the old
# unix-call table. Prints RESULT and exits 0 only if the call goes through.
# Runtime 5.0.1: the stand-in also looks old names up at run time (alias_call),
# asks for its own old-named export, a forward to an old ntdll name and names
# built from the old prefix (alias_more, which must return 0), and an
# ordinary program (aliasprobe.exe) must find none of them in ntdll; the
# stand-in's file is the same after the run (only its memory is rewritten).
set -euo pipefail
ENGINE=$1
BOTTLE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/tests/aliases
WORK=$(mktemp -d)
PE=$ENGINE/lib/ano/x86_64-windows
UNIX=$ENGINE/lib/ano/x86_64-unix

x86_64-w64-mingw32-dlltool -d "$SRC/ntdll-aliases.def" -l "$WORK/libntdll-aliases.a"
x86_64-w64-mingw32-gcc -shared -O2 -o "$WORK/aliastest.dll" "$SRC/aliastest.c" "$SRC/aliastest.def" \
  "$WORK/libntdll-aliases.a"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/aliasrun.exe" "$SRC/aliasrun.c"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/aliasprobe.exe" "$SRC/aliasprobe.c"
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
before=$(shasum -a 256 "$PE/aliastest.dll" | cut -d' ' -f1)
# warn+module names a missing import. ano-dbg is disabled and the run is
# stopped after three minutes: a crash dialog would wait for a click. The
# output goes to a file: processes the run starts may keep a pipe open.
export ANOPREFIX=$BOTTLE DYLD_FALLBACK_LIBRARY_PATH=$ENGINE/lib ANODEBUG=warn+module,+loaddll
export ANODLLOVERRIDES="mscoree=d;mshtml=d;ano-dbg.exe=d"
code=0
perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 180 "$ENGINE/bin/ano-loader" "$WORK/aliasrun.exe" \
  > "$WORK/out.txt" 2>&1 || code=$?
"$ENGINE/bin/ano-server" -k 2> /dev/null || true
probe=0
perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 180 "$ENGINE/bin/ano-loader" "$WORK/aliasprobe.exe" \
  > "$WORK/probe.txt" 2>&1 || probe=$?
"$ENGINE/bin/ano-server" -k 2> /dev/null || true
after=$(shasum -a 256 "$PE/aliastest.dll" | cut -d' ' -f1)
rm -f "$PE/aliastest.dll" "$UNIX/aliastest.so"
cat "$WORK/out.txt"
echo "aliasrun.exe exit $code$([ "$code" != 142 ] || echo ' (stopped after 180 s)')"
grep -a 'PROBE' "$WORK/probe.txt" || cat "$WORK/probe.txt"
echo "aliasprobe.exe exit $probe$([ "$probe" != 142 ] || echo ' (stopped after 180 s)')"
fails=0
grep -q 'RESULT: alias_call(21) = 42' "$WORK/out.txt" \
  || { echo "::error::the stand-in for D3DMetal does not get ntdll's functions by their old names"; fails=1; }
grep -q 'MORE: alias_more() = 0x0' "$WORK/out.txt" \
  || { echo "::error::the stand-in misses an old name (alias_more bits: 1 its own old-named export, 2 a forward" \
    "to an old ntdll name, 4 a name built from the old prefix, 8 one built from a format)"; fails=1; }
grep -q 'PROBE: ntdll hides the old names' "$WORK/probe.txt" \
  || { echo "::error::an ordinary program finds ntdll's old names"; fails=1; }
[ "$before" = "$after" ] || { echo "::error::the marked DLL's file changed ($before, then $after)"; fails=1; }
[ "$fails" = 0 ]
