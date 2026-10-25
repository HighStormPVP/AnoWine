#!/bin/bash
# Spike go/no-go #1: can a dylib be injected into the prebuilt Wine processes,
# and which process makes each network call? Throwaway.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LIB="$SPIKE_WORK/runtime/Libraries"
WINE="$LIB/Wine/bin/wine64"
SERVER="$LIB/Wine/bin/wineserver"
PREFIX="$SPIKE_WORK/prefix-injection"
LOG="$SPIKE_LOGS/injection.log"

spike_fetch_runtime "$SPIKE_WORK/runtime"
ls -la "$LIB/Wine/bin" > "$SPIKE_LOGS/wine-bin-listing.txt"

echo "== 1. codesign flags"
for b in "$WINE" "$SERVER"; do
  echo "--- $b" >> "$SPIKE_LOGS/codesign.txt"
  codesign -dv --verbose=4 "$b" >> "$SPIKE_LOGS/codesign.txt" 2>&1 || echo "(unsigned or unreadable)" >> "$SPIKE_LOGS/codesign.txt"
done
if grep -Eq 'flags=.*(runtime|library-validation)' "$SPIKE_LOGS/codesign.txt"; then
  echo "NOTE: hardened runtime or library validation flag present"
else
  echo "NOTE: no hardened-runtime / library-validation flags"
fi
grep -E '^(---|Executable|Identifier|CodeDirectory|Signature|flags)' "$SPIKE_LOGS/codesign.txt" || cat "$SPIKE_LOGS/codesign.txt"

spike_boot_prefix "$WINE" "$PREFIX"
spike_start_echo
: > "$LOG"
export WINEPREFIX="$PREFIX" WINEDEBUG=-all ANOWINE_SPIKE_LOG="$LOG"
# Inject only into Wine, via the shim. Exporting DYLD_INSERT_LIBRARIES in this
# shell would also push the x86_64-only dylib into arm64 helpers (sleep, grep),
# which abort - see spikes/REPORT.md.
injected() {
  ANOWINE_INSERT="$SPIKE_BIN/liblogshim.dylib" spike_timeout 120     "$SPIKE_BIN/shim" "$WINE" "$SPIKE_BIN/netprobe.exe" "$@"
}

echo "== 2. TCP under injection"
expect_exit 0 "netprobe tcp 127.0.0.1 7001 with logshim" -- injected tcp 127.0.0.1 7001

echo "== 3. connect logged"
if grep -q ' connect .*127\.0\.0\.1:7001' "$LOG"; then pass "connect to 127.0.0.1:7001 logged"; else fail "no connect line for 127.0.0.1:7001"; fi

echo "== 4. DNS under injection"
expect_exit 0 "netprobe dns example.com" -- injected dns example.com
if grep -q ' getaddrinfo .*example\.com' "$LOG"; then pass "getaddrinfo example.com logged"; else fail "no getaddrinfo line for example.com"; fi

echo "== 5. UDP under injection"
expect_exit 0 "netprobe udp two destinations" -- injected udp 127.0.0.1 7002 127.0.0.2 7003

spike_kill_server "$WINE" "$PREFIX"
spike_stop_echo

echo "== Which process makes which call (count, process, call):"
awk '{print $2, $3}' "$LOG" | sort | uniq -c | sort -k2,3 | tee "$SPIKE_LOGS/injection-calls.txt"
echo "== SOCK_DGRAM lines (type 2):"
grep -E ' (socket|sendto|sendmsg|recvfrom|recvmsg|bind) [0-9-]+/2 ' "$LOG" | awk '{print $2, $3, $5}' | sort | uniq -c | tee "$SPIKE_LOGS/injection-udp-calls.txt"

spike_finish "probe_injection"
