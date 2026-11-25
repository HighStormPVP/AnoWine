#!/bin/bash
# check-hidden-names.sh <Libraries> <bottle>: runtime 5.0.1. A Windows program
# finds no "wine" by name (docs/superpowers/specs/2026-11-18-ano-full-rename-design.md,
# "Amended by the owner (2026-11-25, runtime 5.0.1)"):
#  1. no file of the runtime or the bottle holds a hidden alias as text. This is
#     the token scan with the allowlist minus its alias rows: the engine keeps the
#     old names it needs encoded and decodes them only in memory;
#  2. the copyright line "the Wine project authors" is left only in the license
#     texts. No file under <Libraries> outside Ano/share/ano/licenses, and none in
#     the bottle's drive_c, holds it (ASCII or UTF-16LE), and kernel32.dll's
#     version resource has the new line.
# Exit 0 hidden, 1 found, 2 harness error.
set -euo pipefail
LIBS=${1:?usage: check-hidden-names.sh <Libraries> <bottle>}
BOTTLE=${2:?usage: check-hidden-names.sh <Libraries> <bottle>}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
[ -d "$LIBS/Ano/lib" ] || { echo "::error::no engine in $LIBS (expected Ano/lib)"; exit 2; }
[ -d "$BOTTLE/drive_c" ] || { echo "::error::no bottle at $BOTTLE (expected drive_c)"; exit 2; }
fails=0

# 1. Tokens, with no alias allowed.
awk -F'\t' '$2 != "alias"' "$HERE/wine-allowlist.txt" > "$WORK/strict.txt"
dropped=$(( $(grep -c . "$HERE/wine-allowlist.txt") - $(grep -c . "$WORK/strict.txt") ))
code=0
python3 "$HERE/wine_tokens.py" "$LIBS" "$BOTTLE" --allowlist "$WORK/strict.txt" --out "$WORK/tokens.tsv" \
  --gate > "$WORK/tokens.txt" 2>&1 || code=$?
tokens=0
case "$code" in
  0) ;;
  1)
    cat "$WORK/tokens.txt"
    tokens=$(awk -F'\t' 'NR > 1 && $2 !~ /^allowlisted:/' "$WORK/tokens.tsv" | grep -c . || true)
    echo "::error::$tokens old name(s) readable in the runtime or the bottle (the scan allows no alias)"
    fails=1
    ;;
  *) cat "$WORK/tokens.txt"; echo "::error::wine_tokens.py exit $code"; exit 2 ;;
esac

# 2. The copyright line.
code=0
python3 - "$LIBS" "$BOTTLE/drive_c" > "$WORK/copyright.txt" << 'PY' || code=$?
import os
import sys

libs, drive_c = sys.argv[1:3]
OLD = "the Wine project authors"
NEW = "the authors listed in the file AUTHORS"
patterns = (OLD.encode("ascii"), OLD.encode("utf-16-le"))
licenses = os.path.join(libs, "Ano", "share", "ano", "licenses")
hits = []
for root in (libs, drive_c):
    for folder, dirs, files in os.walk(root):
        if os.path.normpath(folder) == os.path.normpath(licenses):
            dirs[:] = []
            continue
        for name in files:
            path = os.path.join(folder, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as handle:
                data = handle.read()
            if any(p in data for p in patterns):
                hits.append(path)
for path in hits[:20]:
    print(f"::error::the old copyright line is in {path}")
kernel32 = os.path.join(libs, "Ano", "lib", "ano", "x86_64-windows", "kernel32.dll")
new_found = os.path.isfile(kernel32) and NEW.encode("utf-16-le") in open(kernel32, "rb").read()
if not new_found:
    print(f"::error::kernel32.dll's version resource does not say \"{NEW}\"")
print(f"old copyright {len(hits)}, new copyright {'in' if new_found else 'not in'} kernel32.dll")
sys.exit(1 if hits or not new_found else 0)
PY
cat "$WORK/copyright.txt"
case "$code" in
  0) ;;
  1) fails=1 ;;
  *) echo "::error::the copyright scan failed (exit $code)"; exit 2 ;;
esac

[ "$fails" = 0 ] || exit 1
echo "old names hidden: tokens 0 ($dropped alias rows not allowed), old copyright 0, new copyright in kernel32.dll"
