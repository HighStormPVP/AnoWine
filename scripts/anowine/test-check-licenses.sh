#!/bin/bash
# Tests check-licenses.sh on fixture runtimes made here: a complete one passes;
# a file no component covers, an empty or missing license text, a NOTICES
# without a component, and a runtime with no licenses folder each fail and
# name the cause; a malformed manifest is exit 2. Runs on Linux (AnoWine
# Hygiene) and macOS.
# Usage: scripts/anowine/test-check-licenses.sh [repo-root]
set -euo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
script=$ROOT/scripts/anowine/check-licenses.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The manifest: component, version, spdx, source, license-files, covers,
# modified. mono comes before the engine, whose share/ano/** would match its
# files too (first match wins).
manifest=$tmp/licenses.txt
{
  echo '# component	version	spdx	source	license-files	covers	modified'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    mono 1.0 MIT payload:licenses/mono COPYING 'Ano/share/ano/mono/**' 'renamed files and strings' \
    dxvk 2.0 Zlib payload:licenses/dxvk LICENSE 'DXVK/**' 'renamed strings' \
    foo 1.2.3 MIT nix:foo 'COPYING,doc/AUTHORS' 'Ano/lib/libfoo.*,Ano/lib/**/libfoo-plugin.dylib' no \
    shims 1 NOASSERTION recipe - 'Ano/lib/shims/*' no \
    engine 11.19 LGPL-2.1-or-later winecx 'COPYING.LIB,LICENSE' \
      'Ano/bin/*,Ano/lib/ano/**,Ano/share/ano/**,AnoRuntimeVersion.plist' 'renamed files and strings'
} > "$manifest"

# make_tree <dir>: a complete runtime for that manifest.
make_tree() {
  local L=$1/Libraries A=$1/Libraries/Ano
  mkdir -p "$A/bin" "$A/lib/ano/x86_64-unix" "$A/lib/gstreamer-1.0" "$A/lib/shims" \
    "$A/share/ano/mono/ano-mono-1.0/lib" "$L/DXVK/x64"
  printf 'x' > "$A/bin/ano-server"
  printf 'x' > "$A/lib/ano/x86_64-unix/ntdll.so"
  ln -s ../lib/ano/x86_64-unix/ntdll.so "$A/bin/ano-loader" 2> /dev/null || true
  printf 'x' > "$A/lib/libfoo.1.dylib"
  ln -s libfoo.1.dylib "$A/lib/libfoo.dylib" 2> /dev/null || true
  printf 'x' > "$A/lib/gstreamer-1.0/libfoo-plugin.dylib"
  printf 'x' > "$A/lib/libfoo-plugin.dylib"
  printf 'x' > "$A/lib/shims/a.dll"
  printf 'x' > "$A/share/ano/mono/ano-mono-1.0/lib/mscorlib.dll"
  printf 'x' > "$L/DXVK/x64/d3d11.dll"
  printf 'x' > "$L/AnoRuntimeVersion.plist"
  local lic=$A/share/ano/licenses
  mkdir -p "$lic/mono" "$lic/dxvk" "$lic/foo/doc" "$lic/engine"
  echo 'mono text' > "$lic/mono/COPYING"
  echo 'dxvk text' > "$lic/dxvk/LICENSE"
  echo 'foo text' > "$lic/foo/COPYING"
  echo 'foo authors' > "$lic/foo/doc/AUTHORS"
  echo 'lgpl text' > "$lic/engine/COPYING.LIB"
  echo 'engine text' > "$lic/engine/LICENSE"
  {
    echo 'Ano engine 5.0.0'
    echo
    echo 'Component | Version | License | Source | Changed by Ano'
    echo '--- | --- | --- | --- | ---'
    echo 'mono | 1.0 | MIT | build-payloads.sh | renamed files and strings'
    echo 'dxvk | 2.0 | Zlib | build-payloads.sh | renamed strings'
    echo 'foo | 1.2.3 | MIT | nixpkgs foo | no'
    echo 'shims | 1 | NOASSERTION | recipe | no'
    echo 'engine | 11.19 | LGPL-2.1-or-later | engine source | renamed files and strings'
  } > "$A/share/ano/NOTICES"
}

fail=0
# check <expected exit> <label> [text the output must contain]...: runs the
# script on $tmp/t/Libraries with the fixture manifest.
check() {
  local want=$1 label=$2 code=0 out text
  shift 2
  out=$(bash "$script" "$tmp/t/Libraries" --manifest "$manifest" 2>&1) || code=$?
  for text in "$@"; do
    if ! grep -qF -- "$text" <<< "$out"; then
      echo "FAIL: $label: no '$text' in the output (exit $code)"
      printf '%s\n' "$out" | sed 's/^/    /'
      fail=1
      return
    fi
  done
  if [ "$code" != "$want" ]; then
    echo "FAIL: $label: exit $code, expected $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
    return
  fi
  echo "ok: $label"
}
fresh() { rm -rf "$tmp/t"; mkdir -p "$tmp/t"; make_tree "$tmp/t"; }

fresh
check 0 "a complete runtime passes" "licenses: 5 components" "shims has no license text (NOASSERTION)"

fresh
printf 'x' > "$tmp/t/Libraries/Ano/lib/libnew.1.dylib"
check 1 "a dylib no component covers fails, named" "uncovered: Ano/lib/libnew.1.dylib"

fresh
: > "$tmp/t/Libraries/Ano/share/ano/licenses/foo/COPYING"
check 1 "an empty license text fails, named" "empty license text: foo COPYING"

fresh
rm "$tmp/t/Libraries/Ano/share/ano/licenses/foo/doc/AUTHORS"
check 1 "a missing license text fails, named" "missing license text: foo doc/AUTHORS"

fresh
grep -v '^foo |' "$tmp/t/Libraries/Ano/share/ano/NOTICES" > "$tmp/notices"
mv "$tmp/notices" "$tmp/t/Libraries/Ano/share/ano/NOTICES"
check 1 "a NOTICES without a component fails, named" "not in NOTICES: foo"

fresh
rm -rf "$tmp/t/Libraries/Ano/share/ano/licenses"
check 1 "a runtime with no licenses folder fails" "no licenses folder: Ano/share/ano/licenses" \
  "missing license text: engine COPYING.LIB"

fresh
rm "$tmp/t/Libraries/Ano/share/ano/NOTICES"
check 1 "a runtime with no NOTICES fails" "no NOTICES: Ano/share/ano/NOTICES"

# First match wins: mono's files belong to mono, so mono's missing text is
# reported even though the engine's share/ano/** also matches them.
fresh
rm "$tmp/t/Libraries/Ano/share/ano/licenses/mono/COPYING"
check 1 "a payload under share/ano is its own component" "missing license text: mono COPYING"

# A component without license files must say NOASSERTION; anything else is a
# manifest error (exit 2), as is a line with the wrong number of fields.
fresh
cp "$manifest" "$tmp/good.txt"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "shims" { $3 = "MIT" } { print }' "$tmp/good.txt" > "$manifest"
check 2 "no license files without NOASSERTION is a manifest error" "shims"
printf 'broken\tline\n' >> "$tmp/good.txt"
cp "$tmp/good.txt" "$manifest"
check 2 "a short manifest line is a manifest error" "want 7 fields"

exit $fail
