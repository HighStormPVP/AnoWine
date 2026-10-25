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
# traffic, so only the sandbox's effect on graphics is being tested. Each
# round's log and whether Steam was still running are included in the results,
# so a launch failure is never mistaken for a rendering problem.
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-m2-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PROFILE="$WORK/profile.sb"
RESULTS="$WORK/results"
LOGS="$WORK/logs"
: > "$RESULTS"
: > "$LOGS"
cat > "$PROFILE" <<'SB'
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote unix-socket))
(allow network-outbound (remote ip "*:*"))
SB

# Stop everything in the bottle and wait until the server has really exited,
# so the next round can't hand off to a Steam left over from this one.
stop_bottle() {
  "$SERVER" -k 2>/dev/null || true
  "$SERVER" -w 2>/dev/null || true
}

ask() {
  local answer
  while true; do
    if ! read -r -p "$1 [y/n] " answer; then
      echo "no-answer"
      return
    fi
    case "$answer" in
      y|Y) echo yes; return ;;
      n|N) echo no; return ;;
    esac
  done
}

run_round() {
  local label=$1; shift
  local log="$WORK/$label.log" pid launch rc
  echo
  echo "=== Round: $label"
  echo "Starting Steam. Wait for it to finish loading (this can take a minute)."
  echo "Then: open the Store page, and if you can, launch one installed game."
  stop_bottle
  "$@" "$LOADER" "$STEAM" > "$log" 2>&1 &
  pid=$!
  read -r -p "Press Enter when you've looked (Steam will be closed)... " || true
  if kill -0 "$pid" 2>/dev/null; then
    launch=running
  else
    rc=0
    wait "$pid" || rc=$?
    launch="exited:$rc"
  fi
  stop_bottle
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # Not pkill: that could also hit a Steam running in Whisky or another app.
  while pgrep -f 'steam\.exe' >/dev/null 2>&1; do
    read -r -p "A Steam is still running. Quit it (Steam menu > Exit), then press Enter... " || break
  done
  STEAM_WINDOW=$(ask "[$label] Did Steam's window show its normal interface (not black or blank)?")
  STORE_PAGE=$(ask "[$label] Did the Store page show properly?")
  GAME_OK=$(ask "[$label] Did a game launch and draw properly? (answer n if you didn't try)")
  echo "$label: steam_window=$STEAM_WINDOW store_page=$STORE_PAGE game=$GAME_OK launch=$launch" >> "$RESULTS"
  { echo "--- $label log (last 20 lines)"; tail -n 20 "$log"; } >> "$LOGS"
}

run_round "normal"
run_round "sandboxed" sandbox-exec -f "$PROFILE"

echo
echo "=== Results - please copy everything between the lines and send it back:"
echo "----------------------------------------------------------------"
sw_vers | tr '\n' ' '; echo
sysctl -n machdep.cpu.brand_string
echo "memory_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))"
cat "$RESULTS"
cat "$LOGS"
echo "----------------------------------------------------------------"
