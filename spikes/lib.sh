#!/bin/bash
# Shared setup for the AnoWine feasibility spikes. Throwaway. Source it.
# Every path is absolute; nothing depends on the current directory.

SPIKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIKE_WORK="${SPIKE_WORK:-${RUNNER_TEMP:-/tmp}/anowine-spike}"
SPIKE_BIN="$SPIKE_WORK/bin"       # built netprobe.exe, dylibs, shim
SPIKE_LOGS="$SPIKE_WORK/logs"     # uploaded as the spike-logs artifact
RUNTIME_URL="https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz"
RUNTIME_SHA256="01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3"
mkdir -p "$SPIKE_BIN" "$SPIKE_LOGS"

# Assertion helpers: every probe prints PASS/FAIL lines and counts failures.
SPIKE_FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; SPIKE_FAILS=$((SPIKE_FAILS + 1)); }
# expect_exit <code> <description> -- <command...>
expect_exit() {
  local want=$1 desc=$2; shift 3
  local got=0
  "$@" || got=$?
  if [ "$got" -eq "$want" ]; then pass "$desc (exit $got)"; else fail "$desc (wanted exit $want, got $got)"; fi
}

# spike_timeout <seconds> <command...>  (macOS has no coreutils timeout).
# Pure bash on purpose: exec'ing through a SIP-protected binary such as perl
# would strip DYLD_* variables from the command's environment.
spike_timeout() {
  local secs=$1; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# spike_fetch_runtime <dir>: download frankea v3.1.1, verify, unpack to <dir>/Libraries.
spike_fetch_runtime() {
  local dir=$1
  mkdir -p "$dir"
  if [ ! -d "$dir/Libraries" ]; then
    curl -fsSL -o "$dir/Libraries.tar.gz" "$RUNTIME_URL"
    echo "$RUNTIME_SHA256  $dir/Libraries.tar.gz" | shasum -a 256 -c - || { echo "runtime digest mismatch" >&2; return 1; }
    tar -xzf "$dir/Libraries.tar.gz" -C "$dir"
    rm -f "$dir/Libraries.tar.gz"
    xattr -cr "$dir/Libraries" 2>/dev/null || true
  fi
}

# spike_server_for <loader>: the wineserver path a loader will use.
spike_server_for() {
  echo "${WINESERVER:-$(dirname "$1")/wineserver}"
}

# spike_boot_prefix <loader> <prefix>: create a prefix, then stop its server so
# later runs start a fresh server that inherits the probe's environment.
spike_boot_prefix() {
  local loader=$1 prefix=$2
  local server
  server="$(spike_server_for "$loader")"
  mkdir -p "$prefix"
  WINEPREFIX="$prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
    spike_timeout 300 "$loader" wineboot -i
  WINEPREFIX="$prefix" "$server" -w || true
  WINEPREFIX="$prefix" "$server" -k || true
}

# spike_kill_server <loader> <prefix>
spike_kill_server() {
  WINEPREFIX="$2" "$(spike_server_for "$1")" -k 2>/dev/null || true
  sleep 1
}

# spike_start_echo: TCP 127.0.0.1:7001/7004, UDP 127.0.0.1:7002 and 127.0.0.2:7003.
spike_start_echo() {
  ifconfig lo0 | grep -q 127.0.0.2 || sudo ifconfig lo0 alias 127.0.0.2 up
  python3 "$SPIKE_ROOT/echo_servers.py" > "$SPIKE_LOGS/echo.log" 2>&1 &
  echo $! > "$SPIKE_WORK/echo.pid"
  sleep 1
}

spike_stop_echo() {
  [ -f "$SPIKE_WORK/echo.pid" ] && kill "$(cat "$SPIKE_WORK/echo.pid")" 2>/dev/null || true
}

# spike_finish <probe-name>: print the summary and exit non-zero on failures.
spike_finish() {
  echo "== $1: $SPIKE_FAILS failure(s)"
  [ "$SPIKE_FAILS" -eq 0 ]
}
