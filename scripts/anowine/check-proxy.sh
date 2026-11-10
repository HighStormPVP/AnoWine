#!/bin/bash
# End-to-end check of Ano's proxy (Plan 2a): the interposer, the helper and a
# real Xray SOCKS inbound, watched with tcpdump so a leak is seen, not assumed.
#
# Usage: scripts/anowine/check-proxy.sh --xray <xray> --helper <ano-proxy> \
#          --lib <libano_net.dylib> --native <interposer_native>
# Needs sudo for tcpdump (GitHub's macOS runners have it). macOS only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS="$HERE/proxy-tests"
XRAY="" HELPER="" LIB="" NATIVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --xray) XRAY="$2"; shift ;;
    --helper) HELPER="$2"; shift ;;
    --lib) LIB="$2"; shift ;;
    --native) NATIVE="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
for f in "$XRAY" "$HELPER" "$LIB" "$NATIVE"; do
  [ -x "$f" ] || [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-proxy-XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sudo pkill -INT -f "tcpdump.*$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
wait_port() { for _ in $(seq 1 50); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }

echo "== start echo servers, Xray, helper and packet capture"
python3 "$TESTS/echo_servers.py" > "$WORK/echo.log" 2>&1 &
PIDS+=($!)
sed "s#__ACCESS_LOG__#$WORK/xray-access.log#" "$TESTS/xray-test.json" > "$WORK/xray.json"
"$XRAY" run -c "$WORK/xray.json" > "$WORK/xray.log" 2>&1 &
PIDS+=($!)
wait_port 7000 && wait_port 10808 || { echo "echo servers or Xray did not start"; cat "$WORK/xray.log"; exit 1; }

"$HELPER" --socks5 127.0.0.1:10808 > "$WORK/helper.out" 2> "$WORK/helper.err" &
HELPER_PID=$!
PIDS+=($HELPER_PID)
for _ in $(seq 1 50); do grep -q '^listening ' "$WORK/helper.out" && break; sleep 0.2; done
PORT="$(awk '/^listening /{print $2; exit}' "$WORK/helper.out")"
[ -n "$PORT" ] || { echo "helper did not start"; cat "$WORK/helper.err"; exit 1; }
echo "helper on port $PORT"

IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
FILTER='udp port 53 or net 192.0.2.0/24'
sudo tcpdump -i lo0 -U -w "$WORK/lo0.pcap" "$FILTER" > /dev/null 2>&1 &
[ -n "$IFACE" ] && sudo tcpdump -i "$IFACE" -U -w "$WORK/if.pcap" "$FILTER" > /dev/null 2>&1 &
sleep 2

echo "== native program with the interposer (helper running)"
DYLD_INSERT_LIBRARIES="$LIB" ANO_PROXY_PORT="$PORT" ANO_WINE_DIR=/nonexistent "$NATIVE"; rc=$?
check "native checks 1-7" '[ "$rc" -eq 0 ]'
check "Xray received anotest.example.com:7000 by name" 'grep -q "anotest.example.com:7000" "$WORK/xray-access.log"'

echo "== native program with the interposer (helper down)"
DYLD_INSERT_LIBRARIES="$LIB" ANO_PROXY_PORT=1 ANO_WINE_DIR=/nonexistent "$NATIVE" --helper-down; rc=$?
check "native check 8" '[ "$rc" -eq 0 ]'

echo "== packet capture"
sleep 1
sudo pkill -INT -f "tcpdump.*$WORK"
sleep 1
for pcap in "$WORK"/*.pcap; do
  [ -f "$pcap" ] || continue
  name="$(basename "$pcap")"
  tcpdump -nn -A -r "$pcap" 2>/dev/null > "$WORK/$name.txt"
  check "$name: no packet to 192.0.2.0/24" '! grep -Eq "> 192\.0\.2\.[0-9]+\." "$WORK/$name.txt"'
  check "$name: no DNS query for anotest" '! grep -qi "anotest" "$WORK/$name.txt"'
done

exit "$fail"
