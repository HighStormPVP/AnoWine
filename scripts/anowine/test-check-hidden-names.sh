#!/bin/bash
# Tests check-hidden-names.sh on fixture runtimes made here:
#  - a clean runtime and bottle pass, with the old copyright line only in the
#    license texts;
#  - an old name in a DLL fails and names the token;
#  - the old copyright line in UTF-16LE in a bottle DLL fails;
#  - a kernel32.dll without the new line fails;
#  - a missing bottle is exit 2.
# Runs on Linux (AnoWine Hygiene) and macOS.
# Usage: scripts/anowine/test-check-hidden-names.sh [repo-root]
set -euo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
script=$ROOT/scripts/anowine/check-hidden-names.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

# utf16 <text>: the text as UTF-16LE, as in a version resource.
utf16() { python3 -c 'import sys; sys.stdout.buffer.write(sys.argv[1].encode("utf-16-le"))' "$1"; }

# make_tree <dir>: a runtime and a bottle with nothing to find.
make_tree() {
  local A=$1/Libraries/Ano B=$1/bottle
  mkdir -p "$A/lib/ano/x86_64-windows" "$A/share/ano/licenses/engine" "$B/drive_c/windows/system32"
  { printf 'MZ\0\0Ano builtin DLL\0'; utf16 "Copyright (c) 1993-2026 the authors listed in the file AUTHORS"; } \
    > "$A/lib/ano/x86_64-windows/kernel32.dll"
  printf 'MZ\0\0Ano builtin DLL\0__ano_unix_call\0' > "$A/lib/ano/x86_64-windows/ntdll.dll"
  printf 'Copyright (c) 1993-2026 the Wine project authors (see the file AUTHORS\n' \
    > "$A/share/ano/licenses/engine/LICENSE"
  printf 'MZ\0\0Ano builtin DLL\0' > "$B/drive_c/windows/system32/user32.dll"
}

# expect <name> <code> <text> <dir>: the check on <dir> exits <code> and prints <text>.
expect() {
  local name=$1 want=$2 text=$3 dir=$4 code=0
  bash "$script" "$dir/Libraries" "$dir/bottle" > "$tmp/out.txt" 2>&1 || code=$?
  if [ "$code" != "$want" ] || ! grep -qF -- "$text" "$tmp/out.txt"; then
    echo "FAIL: $name: exit $code (want $want), output:"
    sed 's/^/  | /' "$tmp/out.txt"
    fails=$((fails + 1))
  else
    echo "ok: $name"
  fi
}

make_tree "$tmp/clean"
expect "a clean runtime passes" 0 "old names hidden:" "$tmp/clean"

make_tree "$tmp/mark"
printf 'MZ\0\0Ano builtin DLL\0\0Wine builtin DLL\0' > "$tmp/mark/Libraries/Ano/lib/ano/x86_64-windows/ntdll.dll"
expect "an old name in a DLL fails" 1 $'Wine\t' "$tmp/mark"

make_tree "$tmp/copyright"
{ printf 'MZ\0\0Ano builtin DLL\0'; utf16 "Copyright (c) 1993-2026 the Wine project authors"; } \
  > "$tmp/copyright/bottle/drive_c/windows/system32/user32.dll"
expect "the old copyright line in a bottle DLL fails" 1 "the old copyright line is in" "$tmp/copyright"

make_tree "$tmp/nonew"
printf 'MZ\0\0Ano builtin DLL\0' > "$tmp/nonew/Libraries/Ano/lib/ano/x86_64-windows/kernel32.dll"
expect "kernel32.dll without the new line fails" 1 "does not say" "$tmp/nonew"

make_tree "$tmp/nobottle"
rm -rf "$tmp/nobottle/bottle"
expect "a missing bottle is a harness error" 2 "no bottle at" "$tmp/nobottle"

[ "$fails" = 0 ] || { echo "$fails case(s) failed"; exit 1; }
echo "check-hidden-names.sh: all cases pass"
