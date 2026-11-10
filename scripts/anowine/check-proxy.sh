#!/bin/bash
# End-to-end check of Ano's proxy (Plan 2a): the interposer, the helper and a
# real Xray SOCKS inbound, watched with tcpdump so a leak is seen, not assumed.
#
# Usage: scripts/anowine/check-proxy.sh --xray <xray> --helper <ano-proxy> \
#          --lib <libano_net.dylib> --native <interposer_native> \
#          [--runtime <Libraries-dir> --netprobe <netprobe.exe>]
# With --runtime, a Windows program also runs under the Ano runtime through the
# ano-loader wrapper, as a proxied bottle's programs do.
# Needs sudo for tcpdump (GitHub's macOS runners have it). macOS only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS="$HERE/proxy-tests"
XRAY="" HELPER="" LIB="" NATIVE="" RUNTIME="" NETPROBE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --xray) XRAY="$2"; shift ;;
    --helper) HELPER="$2"; shift ;;
    --lib) LIB="$2"; shift ;;
    --native) NATIVE="$2"; shift ;;
    --runtime) RUNTIME="$(cd "$2" && pwd)"; shift ;;
    --netprobe) NETPROBE="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$RUNTIME" ] || [ -f "$NETPROBE" ] || { echo "--runtime needs --netprobe" >&2; exit 2; }
for f in "$XRAY" "$HELPER" "$LIB" "$NATIVE"; do
  [ -x "$f" ] || [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-proxy-XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  if [ -n "$RUNTIME" ]; then
    for prefix in "$WORK"/prefix-*; do
      [ -d "$prefix" ] && WINEPREFIX="$prefix" "$RUNTIME/Wine/bin/ano-server" -k 2>/dev/null
    done
  fi
  sudo pkill -INT -f "tcpdump.*$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
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

if [ -n "$RUNTIME" ]; then
  BIN="$RUNTIME/Wine/bin"
  WRAP="$("$HELPER" --write-wrapper "$WORK/wrapper")" || { echo "helper could not write the wrapper"; exit 1; }
  # Runs netprobe.exe (or anything) in a bottle. Proxied runs go through the
  # wrapper with the four ANO_* variables, like the app's proxied launches.
  in_bottle() { # <prefix> <proxied 0|1> <program> <args...>; output in $WORK/wine.out
    local prefix="$1" proxied="$2"; shift 2
    if [ "$proxied" -eq 1 ]; then
      WINEPREFIX="$prefix" WINESERVER="$BIN/ano-server" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
        ANO_PROXY_PORT="$PORT" ANO_NET_LIB="$LIB" ANO_WINE_DIR="$RUNTIME/Wine" ANO_REAL_LOADER="$BIN/ano-loader" \
        with_timeout 300 "$WRAP" "$@" > "$WORK/wine.out" 2>&1
    else
      WINEPREFIX="$prefix" WINESERVER="$BIN/ano-server" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
        with_timeout 300 "$BIN/ano-loader" "$@" > "$WORK/wine.out" 2>&1
    fi
  }
  probe() { in_bottle "$@"; local rc=$?; sed 's/^/     wine: /' "$WORK/wine.out" | tr -d '\r' | head -5; return "$rc"; }
  xray_hits() { grep -c "anotest.example.com:7000" "$WORK/xray-access.log" 2>/dev/null || echo 0; }

  echo "== Windows program under Wine, proxied (helper running)"
  P="$WORK/prefix-proxied"
  in_bottle "$P" 1 cmd /c echo ready; rc=$?
  check "proxied bottle boots" '[ "$rc" -eq 0 ]'
  [ "$rc" -eq 0 ] || { echo "     boot output (rc $rc):"; tr -d '\r' < "$WORK/wine.out" | grep -v '^\s*VK_\|mvk-info\|Vulkan extensions' | tail -40 | sed 's/^/     boot: /'; }
  probe "$P" 1 "$NETPROBE" dns anotest.example.com
  check "wine 1 dns gives a placeholder in 198.18.0.0/15" 'grep -Eq "^198\.1[89]\.[0-9]+\.[0-9]+" "$WORK/wine.out"'
  before="$(xray_hits)"
  probe "$P" 1 "$NETPROBE" tcp anotest.example.com 7000; rc=$?
  check "wine 2 TCP by hostname echoes through the proxy" '[ "$rc" -eq 0 ]'
  check "wine 2 Xray received anotest.example.com:7000 by name" '[ "$(xray_hits)" -gt "$before" ]'
  probe "$P" 1 "$NETPROBE" tcp 192.0.2.1 7000; rc=$?
  check "wine 3 TCP to 192.0.2.1:7000 echoes through the proxy" '[ "$rc" -eq 0 ]'
  probe "$P" 1 "$NETPROBE" peer 192.0.2.1 7000
  check "wine 4 getpeername reports 192.0.2.1:7000" 'grep -q "^192\.0\.2\.1:7000" "$WORK/wine.out"'
  probe "$P" 1 "$NETPROBE" udp 192.0.2.1 7001 192.0.2.2 7002; rc=$?
  check "wine 5 UDP to 192.0.2.1/192.0.2.2 gets no reply" '[ "$rc" -eq 1 ]'
  # Lookups that bypass getaddrinfo; the packet capture below is the real check.
  probe "$P" 1 "$NETPROBE" dnsquery anotest-dnsquery.example.com; rc=$?
  check "wine 9 DnsQuery_A is refused" '[ "$rc" -eq 1 ]'
  probe "$P" 1 "$NETPROBE" hostbyaddr 192.0.2.9; rc=$?
  check "wine 9 gethostbyaddr(192.0.2.9) is refused" '[ "$rc" -eq 1 ]'

  echo "== Windows program under Wine, proxied (helper down)"
  kill "$HELPER_PID" 2>/dev/null; wait "$HELPER_PID" 2>/dev/null
  WINEPREFIX="$P" "$BIN/ano-server" -k 2>/dev/null; WINEPREFIX="$P" "$BIN/ano-server" -w 2>/dev/null
  probe "$P" 1 "$NETPROBE" tcp anotest.example.com 7000; rc=$?
  check "wine 7 helper down: TCP by hostname fails" '[ "$rc" -eq 1 ]'
  probe "$P" 1 "$NETPROBE" tcp 192.0.2.1 7000; rc=$?
  check "wine 7 helper down: TCP to 192.0.2.1 fails" '[ "$rc" -eq 1 ]'
  WINEPREFIX="$P" "$BIN/ano-server" -k 2>/dev/null

  echo "== Windows program under Wine, proxy off"
  "$HELPER" --socks5 127.0.0.1:10808 > "$WORK/helper2.out" 2> "$WORK/helper2.err" &
  PIDS+=($!)
  for _ in $(seq 1 50); do grep -q '^listening ' "$WORK/helper2.out" && break; sleep 0.2; done
  Q="$WORK/prefix-direct"
  in_bottle "$Q" 0 cmd /c echo ready; rc=$?
  check "direct bottle boots" '[ "$rc" -eq 0 ]'
  probe "$Q" 0 "$NETPROBE" tcp 127.0.0.1 7000; rc=$?
  check "wine 8 proxy off: TCP to 127.0.0.1:7000 works" '[ "$rc" -eq 0 ]'
  check "wine 8 proxy off: the helper saw nothing" '! grep -q "^accepted" "$WORK/helper2.err"'
  WINEPREFIX="$Q" "$BIN/ano-server" -k 2>/dev/null
fi

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
  check "$name: no reverse lookup of 192.0.2.x" '! grep -qi "2\.0\.192\.in-addr" "$WORK/$name.txt"'
  grep -i "anotest\|2\.0\.192\.in-addr" "$WORK/$name.txt" | head -5 | sed 's/^/     leak: /'
done

exit "$fail"
