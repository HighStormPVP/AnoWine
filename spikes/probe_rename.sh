#!/bin/bash
# Spike: do the Wine programs still work renamed to anowine / anowine-server?
# Throwaway. A failure here means "keep the original names" (spec section 7).
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

spike_fetch_runtime "$SPIKE_WORK/runtime"
RLIB="$SPIKE_WORK/renamed/Libraries"
rm -rf "$SPIKE_WORK/renamed" && mkdir -p "$SPIKE_WORK/renamed"
cp -R "$SPIKE_WORK/runtime/Libraries" "$RLIB"
BIN="$RLIB/Wine/bin"
PREFIX="$SPIKE_WORK/prefix-rename"
WINETRICKS="$(cd "$SPIKE_ROOT/.." && pwd)/Libraries/winetricks"

echo "== bin before rename"
ls -la "$BIN" | tee "$SPIKE_LOGS/rename-bin-before.txt"

# rename_real <old> <new>: rename the real executable behind <old> to <new>.
rename_real() {
  local old="$BIN/$1" new="$BIN/$2"
  if [ -L "$old" ]; then
    local target
    target="$(readlink "$old")"
    echo "RECIPE: $1 is a symlink to $target; renaming $target -> $2 and removing $1"
    mv "$BIN/$(basename "$target")" "$new"
    rm -f "$old"
  else
    echo "RECIPE: $1 is a real file; renaming -> $2"
    mv "$old" "$new"
  fi
}
rename_real wine64 anowine
rename_real wineserver anowine-server
echo "== bin after rename"
ls -la "$BIN" | tee "$SPIKE_LOGS/rename-bin-after.txt"
echo "== dangling symlinks after rename (should be none):"
find "$BIN" -type l ! -exec test -e {} \; -print | tee "$SPIKE_LOGS/rename-dangling.txt"

export WINESERVER="$BIN/anowine-server" WINEPREFIX="$PREFIX" WINEDEBUG=-all
mkdir -p "$PREFIX"

echo "== 1. wineboot with renamed programs"
expect_exit 0 "anowine wineboot -i" -- spike_timeout 300 env WINEDLLOVERRIDES="mscoree,mshtml=" "$BIN/anowine" wineboot -i
"$WINESERVER" -w || true

echo "== 2. process names"
"$WINESERVER" -p 30
expect_exit 0 "anowine netprobe dns example.com" -- spike_timeout 120 "$BIN/anowine" "$SPIKE_BIN/netprobe.exe" dns example.com
ps -axo comm > "$SPIKE_LOGS/rename-ps.txt"
grep -E 'anowine|wine' "$SPIKE_LOGS/rename-ps.txt" | sort | uniq -c
if grep -Eq '(^|/)anowine-server$' "$SPIKE_LOGS/rename-ps.txt"; then pass "anowine-server is running"; else fail "no anowine-server process"; fi
if grep -Eq '(^|/)(wineserver|wine64)$' "$SPIKE_LOGS/rename-ps.txt"; then fail "a process still named wineserver/wine64"; else pass "no wineserver/wine64 process names"; fi

echo "== 3. TCP with renamed programs"
spike_start_echo
expect_exit 0 "anowine netprobe tcp 127.0.0.1 7001" -- spike_timeout 120 "$BIN/anowine" "$SPIKE_BIN/netprobe.exe" tcp 127.0.0.1 7001
spike_stop_echo

echo "== 4. winetricks with WINE/WINESERVER pointed at renamed programs"
expect_exit 0 "winetricks list-installed" -- spike_timeout 300 env WINE="$BIN/anowine" PATH="$BIN:$PATH" bash "$WINETRICKS" list-installed

"$WINESERVER" -k 2>/dev/null || true
spike_finish "probe_rename"
