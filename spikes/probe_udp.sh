#!/bin/bash
# Spike go/no-go #3: can Wine's UDP be carried with no real UDP packet leaving
# the sandboxed Wine processes? Throwaway.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LIB="$SPIKE_WORK/runtime/Libraries"
WINE="$LIB/Wine/bin/wine64"
PREFIX="$SPIKE_WORK/prefix-udp"
PROFILE="$SPIKE_ROOT/sandbox/net-lockdown.sb"
LOG="$SPIKE_LOGS/udp.log"
RELAY_SOCK="/tmp/anowine-udp-relay.sock"
RELAY_LOG="$SPIKE_LOGS/udp-relay.log"

spike_fetch_runtime "$SPIKE_WORK/runtime"
spike_boot_prefix "$WINE" "$PREFIX"
spike_start_echo
: > "$LOG"; : > "$RELAY_LOG"
python3 "$SPIKE_ROOT/udp_relay.py" "$RELAY_SOCK" "$RELAY_LOG" &
RELAY_PID=$!
sleep 1

export WINEPREFIX="$PREFIX" WINEDEBUG=-all ANOWINE_SPIKE_LOG="$LOG" ANOWINE_UDP_RELAY="$RELAY_SOCK"
spike_kill_server "$WINE" "$PREFIX"

echo "== 1. UDP to two destinations through the relay, sandboxed"
OUT="$SPIKE_LOGS/udp-netprobe.txt"
rc=0
ANOWINE_INSERT="$SPIKE_BIN/libudpshim.dylib" spike_timeout 120 \
  sandbox-exec -D ALLOW_PORT=7001 -f "$PROFILE" \
  "$SPIKE_BIN/shim" "$WINE" "$SPIKE_BIN/netprobe.exe" udp 127.0.0.1 7002 127.0.0.2 7003 > "$OUT" 2>&1 || rc=$?
cat "$OUT"
if [ "$rc" -eq 0 ]; then pass "netprobe udp exit 0"; else fail "netprobe udp exit $rc"; fi
if grep -q 'from 127.0.0.1:7002 U1' "$OUT"; then pass "reply from 127.0.0.1:7002 with true source"; else fail "missing/incorrect reply from 127.0.0.1:7002"; fi
if grep -q 'from 127.0.0.2:7003 U2' "$OUT"; then pass "reply from 127.0.0.2:7003 with true source"; else fail "missing/incorrect reply from 127.0.0.2:7003"; fi

echo "== 2. traffic went through the relay"
cat "$RELAY_LOG"
if [ "$(grep -c '^out ' "$RELAY_LOG")" -ge 2 ] && [ "$(grep -c '^in ' "$RELAY_LOG")" -ge 2 ]; then
  pass "relay carried both datagrams each way"
else
  fail "relay did not see both datagrams each way"
fi

echo "== 3. calls Wine made on substituted fds"
grep -E 'socket-sub|subcall' "$LOG" | awk '{ $1=""; print }' | sed -E 's/fd=[0-9]+/fd=N/; s/path=[^ ]+/path=P/' | sort | uniq -c | tee "$SPIKE_LOGS/udp-subcalls.txt"
echo "== which process created substituted sockets:"
grep 'socket-sub' "$LOG" | awk '{print $2}' | sort | uniq -c

spike_kill_server "$WINE" "$PREFIX"
kill "$RELAY_PID" 2>/dev/null || true
spike_stop_echo
spike_finish "probe_udp"
