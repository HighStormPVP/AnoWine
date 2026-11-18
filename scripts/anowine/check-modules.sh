#!/bin/bash
# Fails unless the ntdll.so that build-modules.sh built matches the engine it
# replaces a file in: same architecture, same minimum macOS, same exported
# symbols, same imports (minus _setprogname, which ntdll-no-proctitle.patch
# removes), and it starts the loader as ano-core. A mismatch means the module
# was built from different source or with different settings than the engine.
#
# Usage: scripts/anowine/check-modules.sh <modules-dir> <engine-ntdll.so>
# <modules-dir> is build-modules.sh's output directory. macOS only.
set -uo pipefail
MODULES="$(cd "${1:?usage: check-modules.sh <modules-dir> <engine-ntdll.so>}" && pwd)"
ENGINE="${2:?usage: check-modules.sh <modules-dir> <engine-ntdll.so>}"
OURS="$MODULES/Wine/lib/wine/x86_64-unix/ntdll.so"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

minos() { otool -l "$1" | awk '/LC_BUILD_VERSION/ {b=1} b && $1 == "minos" {print $2; exit}'; }
exports() { nm -gU "$1" | awk '{print $NF}' | sort; }
imports() { nm -u "$1" | sort; }

[ -f "$OURS" ] || { echo "FAIL built ntdll.so missing at $OURS"; exit 1; }
[ -f "$ENGINE" ] || { echo "FAIL engine ntdll.so missing at $ENGINE"; exit 1; }

check "ntdll.so is x86_64 only" '[ "$(lipo -archs "$OURS")" = x86_64 ]'
check "ntdll.so needs macOS 15.0, like the engine's" \
  '[ "$(minos "$OURS")" = 15.0 ] && [ "$(minos "$ENGINE")" = 15.0 ]'
check "ntdll.so exports what the engine's exports" 'diff <(exports "$ENGINE") <(exports "$OURS") > /dev/null'
check "ntdll.so imports what the engine's imports, except _setprogname" \
  'diff <(imports "$ENGINE" | grep -vx _setprogname) <(imports "$OURS") > /dev/null'
check "ntdll.so starts ano-core" 'grep -aq "%s%s/ano-core" "$OURS"'

if [ "$fail" -ne 0 ]; then
  echo "minos: ours $(minos "$OURS"), engine $(minos "$ENGINE")"
  echo "exports (< engine, > ours):"; diff <(exports "$ENGINE") <(exports "$OURS") | head -20
  echo "imports (< engine without _setprogname, > ours):"
  diff <(imports "$ENGINE" | grep -vx _setprogname) <(imports "$OURS") | head -20
fi
exit "$fail"
