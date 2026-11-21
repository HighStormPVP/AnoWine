#!/bin/bash
# check-app-on-engine.sh <ano CLI> <Libraries>: Plan 3c-4a, Task 7. The app's
# own code (WhiskyKit, through the ano CLI) drives a bottle on engine 5.x:
# the engine is installed where the app keeps its runtime, a bottle is created
# and a program runs in it, and what the app wrote is checked; then a bottle
# from an earlier Ano, already on the app's bottle list (as after an update),
# is listed as such, refused, and left byte for byte as it was.
set -Eeuo pipefail
trap 'echo "::error::check-app-on-engine.sh: line $LINENO: exit $?"' ERR
CLI=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
SRC_LIB=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
APP_LIB="$HOME/Library/Application Support/io.github.highstormpvp.Ano/Libraries"
CONTAINER="$HOME/Library/Containers/io.github.highstormpvp.Ano"
BOTTLES="$CONTAINER/Bottles"
LIST="$CONTAINER/BottleVM.plist"
LOGS=${RUNNER_TEMP:-/tmp}/reports/app-on-engine
fails=0
fail() { echo "::error::the app on Ano's engine: $*"; fails=$((fails + 1)); }
cli() {  # seconds, then the CLI's arguments
  local limit=$1
  shift
  perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$limit" "$CLI" "$@"
}

mkdir -p "$LOGS" "$(dirname "$APP_LIB")"
rm -rf "$APP_LIB" "$CONTAINER"
cp -R "$SRC_LIB" "$APP_LIB"
[ -f "$APP_LIB/AnoRuntimeVersion.plist" ] && [ -x "$APP_LIB/Ano/bin/ano-loader" ] \
  || { echo "::error::$SRC_LIB is not an engine 5.x Libraries folder"; exit 1; }

# 1. A new bottle, and a program run in it the way the app runs one. --follow
#    streams the engine's log and the exit code, not a console program's own
#    output, so the program leaves a file in the bottle.
cli 120 create T > "$LOGS/create.log" 2>&1 || fail "ano create exited $? ($(tail -1 "$LOGS/create.log"))"
code=0
cli 1200 run --follow T 'C:\windows\system32\cmd.exe' /c 'echo app-on-engine-ok> C:\app-on-engine.txt' \
  > "$LOGS/run.log" 2>&1 || code=$?
"$APP_LIB/Ano/bin/ano-server" -k 2> /dev/null || true
tr -d '\r' < "$LOGS/run.log" > "$LOGS/run.lf"
B=$(find "$BOTTLES" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$B" ] || { echo "::error::no bottle under $BOTTLES"; exit 1; }
echo "bottle: $B"
if grep -q "app-on-engine-ok" "$B/drive_c/app-on-engine.txt" 2> /dev/null && grep -q "Exited with code 0" "$LOGS/run.lf"; then
  echo "ano run: the program ran and wrote C:\\app-on-engine.txt (exit $code)"
else
  tail -n 30 "$LOGS/run.lf"
  fail "ano run: no C:\\app-on-engine.txt from the program, or no exit code 0 (exit $code$([ "$code" != 142 ] || echo ', stopped after 1200 s'))"
fi

# 2. What the app wrote: the engine's registry, Software\Ano, no wine keys.
head -n 1 "$B/system.reg" | grep -q "^ANO REGISTRY" || fail "system.reg does not start with ANO REGISTRY"
if grep -l 'Software\\\\Wine' "$B"/*.reg; then fail "the registry has a Software\\Wine key"; fi
grep -q '^\[Software\\\\Ano' "$B/user.reg" || fail "user.reg has no Software\\Ano key"
plutil -convert xml1 -o "$LOGS/Metadata.xml" "$B/Metadata.plist"
if grep -i "<key>[^<]*wine" "$LOGS/Metadata.xml"; then fail "Metadata.plist has a key with wine in it"; fi

# 3. The Terminal environment the app gives the bottle.
cli 120 shellenv T > "$LOGS/shellenv.txt" 2>&1 || fail "ano shellenv exited $?"
grep -q "ANOPREFIX" "$LOGS/shellenv.txt" || fail "ano shellenv sets no ANOPREFIX"
if grep -E "WINE[A-Z0-9_]*=" "$LOGS/shellenv.txt"; then fail "ano shellenv sets a WINE variable"; fi

# 4. The gate over the bottle the app made.
python3 "$HERE/wine_tokens.py" "$B" --allowlist "$HERE/wine-allowlist.txt" --out "$LOGS/bottle-tokens.tsv" --gate \
  || fail "the gate found wine tokens in the bottle"

# 5. A bottle from an earlier Ano, on the list as an update leaves it.
OLD="$BOTTLES/old-$(uuidgen)"
mkdir -p "$OLD/drive_c"
printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n' > "$OLD/system.reg"
cp "$OLD/system.reg" "$OLD/user.reg"
plutil -create xml1 "$OLD/Metadata.plist"
plutil -insert wineConfig -dictionary "$OLD/Metadata.plist"
plutil -insert wineConfig.windowsVersion -string win7 "$OLD/Metadata.plist"
python3 - "$LIST" "$OLD" << 'PY'
import plistlib, sys
path, old = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    data = plistlib.load(f)
entry = data["paths"][0]
url = "file://" + old + "/"
if isinstance(entry, dict):  # how PropertyListEncoder writes a URL
    new = dict(entry)
    new["relative"] = url
else:
    new = url
print(f"bottle list entry: {entry!r} -> {new!r}")
data["paths"].append(new)
with open(path, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
PY
snapshot() { (cd "$OLD" && find . -type f -print0 | sort -z | xargs -0 stat -f '%N %z %m' && find . | sort) | shasum -a 256; }
before=$(snapshot)
cli 120 list > "$LOGS/list.txt" 2>&1 || fail "ano list exited $?"
cat "$LOGS/list.txt"
grep -q "Made with an earlier Ano" "$LOGS/list.txt" || fail "ano list does not mark the earlier Ano's bottle"
grep -qw "T" "$LOGS/list.txt" || fail "ano list lost the new bottle"
old_name=$(basename "$OLD")
code=0
cli 300 run "$old_name" 'C:\windows\system32\cmd.exe' /c echo x > "$LOGS/old-run.log" 2>&1 || code=$?
cat "$LOGS/old-run.log"
[ "$code" != 0 ] || fail "ano run accepted the earlier Ano's bottle"
grep -qi "earlier" "$LOGS/old-run.log" || fail "ano run's refusal does not say the bottle is from an earlier Ano"
[ "$(snapshot)" = "$before" ] || fail "the earlier Ano's bottle changed"
"$APP_LIB/Ano/bin/ano-server" -k 2> /dev/null || true

[ "$fails" -eq 0 ] || { echo "the app on Ano's engine: $fails check(s) failed"; exit 1; }
echo "the app on Ano's engine: all checks passed"
