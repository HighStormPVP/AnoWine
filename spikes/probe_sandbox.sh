#!/bin/bash
# Spike go/no-go #2: does a sandbox-exec profile lock a Wine bottle's network
# down to one localhost port, with the interposer still loaded? Throwaway.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LIB="$SPIKE_WORK/runtime/Libraries"
WINE="$LIB/Wine/bin/wine64"
PREFIX="$SPIKE_WORK/prefix-sandbox"
PROFILE="$SPIKE_ROOT/sandbox/net-lockdown.sb"
LOG="$SPIKE_LOGS/sandbox.log"

spike_fetch_runtime "$SPIKE_WORK/runtime"
spike_boot_prefix "$WINE" "$PREFIX"
spike_start_echo
: > "$LOG"
export WINEPREFIX="$PREFIX" WINEDEBUG=-all ANOWINE_SPIKE_LOG="$LOG"

# boxed <netprobe args...>: run netprobe in the locked-down sandbox, interposer armed.
boxed() {
  ANOWINE_INSERT="$SPIKE_BIN/liblogshim.dylib" spike_timeout 120 \
    sandbox-exec -D ALLOW_PORT=7001 -f "$PROFILE" \
    "$SPIKE_BIN/shim" "$WINE" "$SPIKE_BIN/netprobe.exe" "$@"
}

# The server must be born inside the sandbox, so stop any running one first.
spike_kill_server "$WINE" "$PREFIX"

echo "== 1. Wine runs sandboxed; allowed port reachable"
expect_exit 0 "boxed tcp 127.0.0.1 7001" -- boxed tcp 127.0.0.1 7001
echo "== 2. other local port blocked"
expect_exit 1 "boxed connect 127.0.0.1 7004" -- boxed connect 127.0.0.1 7004
echo "== 3. internet blocked"
expect_exit 1 "boxed connect 1.1.1.1 443" -- boxed connect 1.1.1.1 443
echo "== 4. UDP blocked"
expect_exit 1 "boxed udp" -- boxed udp 127.0.0.1 7002 127.0.0.2 7003
echo "== 5. interposer survived sandbox-exec (via shim) in loader and server"
awk '{print $2}' "$LOG" | sort | uniq -c | tee "$SPIKE_LOGS/sandbox-procs.txt"
if [ "$(awk '{print $2}' "$LOG" | sort -u | wc -l)" -ge 2 ] && grep -q ' wineserver ' "$LOG"; then
  pass "logshim loaded in the loader and in wineserver"
else
  fail "logshim missing from loader or wineserver"
fi
echo "== 7. local DNS blocked (mDNSResponder) inside the sandbox"
expect_exit 1 "boxed dns example.com" -- boxed dns example.com

spike_kill_server "$WINE" "$PREFIX"
echo "== 6. control: same connect without the sandbox succeeds"
expect_exit 0 "unboxed connect 1.1.1.1 443" -- spike_timeout 120 "$WINE" "$SPIKE_BIN/netprobe.exe" connect 1.1.1.1 443
expect_exit 0 "unboxed dns example.com" -- spike_timeout 120 "$WINE" "$SPIKE_BIN/netprobe.exe" dns example.com

spike_kill_server "$WINE" "$PREFIX"
spike_stop_echo
spike_finish "probe_sandbox"
