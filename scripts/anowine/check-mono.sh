#!/bin/bash
# check-mono.sh <Libraries/Ano> <bottle> (Plan 3c-2): the renamed wine-mono
# runs a .NET program in the bottle. tests/mono/hello.cs is compiled with the
# runner's .NET SDK (Roslyn) against the engine's own mscorlib, then run with
# ano-loader; it must print "hello from Ano mono".
set -euo pipefail
ENGINE=$1
BOTTLE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
MONO=$ENGINE/share/ano/mono/ano-mono-11.3.0
[ -f "$MONO/lib/mono/4.5/mscorlib.dll" ] || { echo "FAIL: no renamed mono at $MONO"; exit 1; }

dotnet=$(command -v dotnet) || { echo "FAIL: no .NET SDK on this runner"; exit 1; }
root=$(cd "$(dirname "$(readlink "$dotnet" || echo "$dotnet")")" && pwd)
csc=$(find "$root/sdk" -path '*/Roslyn/bincore/csc.dll' | sort -V | tail -n 1)
[ -n "$csc" ] || { echo "FAIL: no Roslyn csc.dll under $root/sdk"; exit 1; }
dotnet "$csc" -nologo -noconfig -nostdlib -r:"$MONO/lib/mono/4.5/mscorlib.dll" \
  -out:"$WORK/hello.exe" "$HERE/tests/mono/hello.cs"

# ano-dbg is off and the run is stopped after three minutes: a crash dialog
# would wait for a click. Output to a file: started processes may hold a pipe.
export ANOPREFIX=$BOTTLE DYLD_FALLBACK_LIBRARY_PATH=$ENGINE/lib ANODEBUG=warn+module
export ANODLLOVERRIDES="ano-dbg.exe=d"
code=0
perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 180 "$ENGINE/bin/ano-loader" "$WORK/hello.exe" \
  > "$WORK/out.txt" 2>&1 || code=$?
"$ENGINE/bin/ano-server" -k 2> /dev/null || true
cat "$WORK/out.txt"
echo "hello.exe exit $code$([ "$code" != 142 ] || echo ' (stopped after 180 s)')"
grep -qx 'hello from Ano mono' <(tr -d '\r' < "$WORK/out.txt")
