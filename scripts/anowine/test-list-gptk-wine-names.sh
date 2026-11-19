#!/bin/bash
# Tests list-gptk-wine-names.sh against a fake D3DMetal store with a Wine
# string in ASCII, one in UTF-16LE and a Wine-folder symlink. Runs on Linux
# (AnoWine Hygiene) and macOS.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

store="$tmp/store"
mkdir -p "$store/lib/external" "$store/lib/wine/x86_64-windows" "$store/lib/wine/x86_64-unix"
printf '\x01___wine_unix_call_dispatcher\x00\x02___wine_unix_call_dispatcher\x00' \
  > "$store/lib/external/libd3dshared.dylib"
printf 'MZ\x00\x00Wine builtin DLL\x00W\x00i\x00n\x00e\x00D\x003\x00D\x00\x00\x00' \
  > "$store/lib/wine/x86_64-windows/d3d12.dll"
ln -s ../../external/libd3dshared.dylib "$store/lib/wine/x86_64-unix/d3d12.so"

out=$(HOME="$tmp" bash "$here/list-gptk-wine-names.sh" "$store")
echo "$out"
fail=0
expect() {
  if grep -qxF "$1" <<< "$out"; then
    echo "ok: $1"
  else
    echo "MISSING: $1"
    fail=1
  fi
}
expect "$(printf 'lib/external/libd3dshared.dylib\tascii\t2\t___wine_unix_call_dispatcher')"
expect "$(printf 'lib/wine/x86_64-windows/d3d12.dll\tascii\t1\tWine builtin DLL')"
expect "$(printf 'lib/wine/x86_64-windows/d3d12.dll\tutf16\t1\tWineD3D')"
expect "$(printf 'lib/wine/x86_64-unix/d3d12.so\tlink\t../../external/libd3dshared.dylib')"
if [ -f "$tmp/Desktop/ano-gptk-wine-names.txt" ]; then
  echo "ok: Desktop copy"
else
  echo "MISSING: $tmp/Desktop/ano-gptk-wine-names.txt"
  fail=1
fi

set +e
HOME="$tmp" bash "$here/list-gptk-wine-names.sh" "$tmp/no-store" > /dev/null 2>&1
code=$?
set -e
if [ "$code" = 1 ]; then
  echo "ok: a missing store exits 1"
else
  echo "WRONG: a missing store exited $code, expected 1"
  fail=1
fi
exit "$fail"
