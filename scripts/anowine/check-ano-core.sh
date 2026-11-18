#!/bin/bash
# Fails unless an unpacked runtime has the Wine loader renamed to ano-core:
# the loader file, the bin/ano-loader link to it, and the name ntdll.so starts
# it by. Optionally boots a prefix and checks the Wine processes: Windows
# programs run as ano-core (or as ano-loader, for one the caller started
# through the link), told apart by their kernel name (ucomm), and each command
# shows the ano-core or ano-loader path, then the Windows program.
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
# Wine's loader finds ntdll.so beside its resolved path, so bin holds a link, not a copy.
check "bin/ano-loader links to ../lib/wine/x86_64-unix/ano-core" \
  '[ -L "$BIN/ano-loader" ] && [ "$(readlink "$BIN/ano-loader")" = ../lib/wine/x86_64-unix/ano-core ]'
check "bin holds only ano-loader and ano-server" '[ "$(ls -A "$BIN" | sort | tr "\n" " ")" = "ano-loader ano-server " ]'
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
  check "nothing ran as wine, wine64, wineloader or wineserver" \
    '! grep -qxE "wine|wine64|wineloader|wineserver" "$PREFIX/names.txt"'
  # Wine must not overwrite a process's arguments with the Windows program (C:\...).
  check "no process command starts with a Windows path" '! grep -qE "^ano-(core|loader) +[A-Za-z]:" "$PREFIX/ps.txt"'
  # Steam detection (WineSteamClientDriver.windowsImageName) reads the Windows program
  # after the ano-core or ano-loader path, so every Wine process must start with one.
  # ps shows "(ano-core)" for a process whose arguments it cannot read (it is
  # starting or exiting); such a sample has no command to check.
  check "every Wine process command starts with the ano-core or ano-loader path" \
    '[ -z "$(grep -E "^ano-(core|loader) " "$PREFIX/ps.txt" | grep -vE "^ano-(core|loader) +\(ano-(core|loader)\)$" |
      grep -vE "^ano-(core|loader) +/[^ ]*/ano-(core|loader)( |$)")" ]'
  echo "Wine processes seen (kernel name, then the command ps shows):"
  awk '$1 ~ /^(ano-|wine)/' "$PREFIX/ps.txt" | sort | uniq -c | sort -rn | head -20
  rm -rf "$PREFIX"
fi
exit "$fail"
