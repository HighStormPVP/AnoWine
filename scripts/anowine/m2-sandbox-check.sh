#!/bin/bash
# AnoWine hardware check: does the macOS sandbox used for the proxy kill switch
# change how Steam and games render? Run it on a real Apple Silicon Mac.
#
# How to run (see docs/anowine/TESTING-ON-M2.md):
#   1. In AnoWine, select the bottle with Steam and click "Open Terminal".
#   2. In that Terminal window: bash ~/Downloads/m2-sandbox-check.sh
#
# It launches Steam twice with the same environment: once normally, once inside
# a sandbox that has the kill switch's structure but still allows all internet
# traffic, so only the sandbox's effect on graphics is being tested.
set -uo pipefail

if [ -z "${WINEPREFIX:-}" ] || ! command -v anowine >/dev/null 2>&1; then
  echo "Please run this from AnoWine's \"Open Terminal\" window for your Steam bottle."
  exit 1
fi
STEAM="${1:-$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe}"
if [ ! -f "$STEAM" ]; then
  echo "Steam not found at: $STEAM"
  echo "Pass the path to steam.exe as the first argument."
  exit 1
fi
LOADER="$(command -v anowine)"
SERVER="${WINESERVER:-$(dirname "$LOADER")/anowine-server}"

# BSD mktemp only fills in trailing X's, so no file extension here.
PROFILE="$(mktemp "${TMPDIR:-/tmp}/anowine-m2-profile-XXXXXX")"
trap 'rm -f "$PROFILE"' EXIT
cat > "$PROFILE" <<'SB'
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote unix-socket))
(allow network-outbound (remote ip "*:*"))
SB

stop_bottle() {
  "$SERVER" -k 2>/dev/null || true
  sleep 3
}

ask() {
  local answer
  while true; do
    read -r -p "$1 [y/n] " answer
    case "$answer" in
      y|Y) echo yes; return ;;
      n|N) echo no; return ;;
    esac
  done
}

run_round() {
  local label=$1; shift
  echo
  echo "=== Round: $label"
  echo "Starting Steam. Wait for it to finish loading (this can take a minute)."
  echo "Then: open the Store page, and if you can, launch one installed game."
  stop_bottle
  "$@" "$LOADER" "$STEAM" >/dev/null 2>&1 &
  read -r -p "Press Enter when you've looked (Steam will be closed)... "
  stop_bottle
  STEAM_WINDOW=$(ask "[$label] Did Steam's window show its normal interface (not black or blank)?")
  STORE_PAGE=$(ask "[$label] Did the Store page show properly?")
  GAME_OK=$(ask "[$label] Did a game launch and draw properly? (answer n if you didn't try)")
  echo "$label: steam_window=$STEAM_WINDOW store_page=$STORE_PAGE game=$GAME_OK" >> "$RESULTS"
}

RESULTS="$(mktemp "${TMPDIR:-/tmp}/anowine-m2-results-XXXXXX")"
run_round "normal"
run_round "sandboxed" sandbox-exec -f "$PROFILE"

echo
echo "=== Results - please copy everything between the lines and send it back:"
echo "----------------------------------------------------------------"
sw_vers | tr '\n' ' '; echo
sysctl -n machdep.cpu.brand_string
echo "memory_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))"
cat "$RESULTS"
echo "----------------------------------------------------------------"
rm -f "$RESULTS"
