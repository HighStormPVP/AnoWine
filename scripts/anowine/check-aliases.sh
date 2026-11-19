#!/bin/bash
# check-aliases.sh <Libraries/Ano> <bottle>: the engine keeps the hidden
# aliases closed parts need (scripts/anowine/aliases.txt). A stand-in for
# Apple's D3DMetal (tests/aliases): a DLL marked "Wine builtin DLL" that
# imports ntdll's old names, with a Mac half that exports only the old
# unix-call table. Prints RESULT and exits 0 only if the call goes through.
set -euo pipefail
ENGINE=$1
BOTTLE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/tests/aliases
WORK=$(mktemp -d)
PE=$ENGINE/lib/ano/x86_64-windows
UNIX=$ENGINE/lib/ano/x86_64-unix

x86_64-w64-mingw32-dlltool -d "$SRC/ntdll-aliases.def" -l "$WORK/libntdll-aliases.a"
x86_64-w64-mingw32-gcc -shared -O2 -o "$WORK/aliastest.dll" "$SRC/aliastest.c" "$WORK/libntdll-aliases.a"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/aliasrun.exe" "$SRC/aliasrun.c"
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
export ANOPREFIX=$BOTTLE DYLD_FALLBACK_LIBRARY_PATH=$ENGINE/lib ANODEBUG=-all ANODLLOVERRIDES="mscoree=d;mshtml=d"
code=0
out=$("$ENGINE/bin/ano-loader" "$WORK/aliasrun.exe" 2>&1) || code=$?
"$ENGINE/bin/ano-server" -k 2> /dev/null || true
rm -f "$PE/aliastest.dll" "$UNIX/aliastest.so"
echo "$out"
echo "aliasrun.exe exit $code"
grep -q 'RESULT: alias_call(21) = 42' <<< "$out"
