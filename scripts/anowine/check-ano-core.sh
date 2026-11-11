#!/bin/bash
# Fails unless an unpacked runtime has the Wine loader renamed to ano-core:
# the loader file, and the name ntdll.so starts it by. Optionally boots a
# prefix and checks every Wine process runs as ano-core. Wine rewrites a
# process's arguments to show the Windows program, so processes are told
# apart by their kernel name (ucomm), which comes from the executable file.
#
# Usage: scripts/anowine/check-ano-core.sh <Libraries-dir> [--boot]
set -uo pipefail
LIB="$(cd "${1:?usage: check-ano-core.sh <Libraries-dir> [--boot]}" && pwd)"
UNIX="$LIB/Wine/lib/wine/x86_64-unix"
BIN="$LIB/Wine/bin"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

check "loader is lib/wine/x86_64-unix/ano-core" '[ -x "$UNIX/ano-core" ] && [ ! -L "$UNIX/ano-core" ]'
check "no loader named wine is left" '[ ! -e "$UNIX/wine" ] && [ ! -L "$UNIX/wine" ]'
check "ntdll.so starts ano-core" 'grep -aq "%s%s/ano-core" "$UNIX/ntdll.so"'
check "ntdll.so no longer starts wine" '! grep -aq "%s%s/wine" "$UNIX/ntdll.so"'
# Wine's set_process_name (dlls/ntdll/unix/env.c) is its only caller of setprogname.
check "ntdll.so does not rename its process (no setprogname)" '! nm -u "$UNIX/ntdll.so" | grep -qw _setprogname'

if [ "${2:-}" = --boot ]; then
  PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/anowine-anocore-XXXXXX")"
  export WINEPREFIX="$PREFIX/prefix" WINESERVER="$BIN/ano-server" WINEDEBUG=-all
  WINEDLLOVERRIDES="mscoree,mshtml=" "$BIN/ano-loader" cmd /c echo ready &
  boot=$!
  : > "$PREFIX/ps.txt"
  while kill -0 "$boot" 2>/dev/null; do ps -axo ucomm=,command= >> "$PREFIX/ps.txt"; sleep 0.5; done
  wait "$boot"; status=$?
  "$WINESERVER" -w
  check "bottle booted" '[ "$status" -eq 0 ] && [ -f "$WINEPREFIX/system.reg" ]'
  awk '{print $1}' "$PREFIX/ps.txt" | sort -u > "$PREFIX/names.txt"
  check "Windows processes ran as ano-core" 'grep -qx "ano-core" "$PREFIX/names.txt"'
  check "nothing ran as wine, wine64 or wineserver" '! grep -qxE "wine|wine64|wineserver" "$PREFIX/names.txt"'
  echo "Wine processes seen (kernel name, then the Windows program it showed):"
  awk '$1 ~ /^(ano-|wine)/' "$PREFIX/ps.txt" | sort | uniq -c | sort -rn | head -20
  rm -rf "$PREFIX"
fi
exit "$fail"
