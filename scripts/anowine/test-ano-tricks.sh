#!/usr/bin/env bash
# Plan 3c-3: checks Libraries/ano-tricks (made by make_ano_tricks.py) without
# an engine: its version, its verb list (the app's verbs there, the dropped
# ones gone), no update check, self-update or stats report reaching the
# network, its cache in Ano's cache folder, and the gate over the file.
# Usage: scripts/anowine/test-ano-tricks.sh [repo-root]
set -euo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
HERE=$ROOT/scripts/anowine
T=$ROOT/Libraries/ano-tricks
PYTHON=${PYTHON:-python3}
fails=0
fail() { echo "::error::ano-tricks: $*"; fails=$((fails + 1)); }

[ -f "$T" ] || { echo "::error::no $T (make it with scripts/anowine/make_ano_tricks.py)"; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/bin" "$work/gate"
# Every downloader logs its call and fails: nothing tested here may reach the network.
for tool in curl wget aria2c fetch; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$tool" "$work" > "$work/bin/$tool"
  chmod +x "$work/bin/$tool"
done
# A cabextract that makes msvcp140.dll_x86 in its --directory when the cabinet's
# path says "present", and nothing otherwise (as for a cabinet that lacks it).
cat > "$work/bin/cabextract" << 'EOF'
#!/bin/sh
for arg; do case $arg in --directory=*) dir=${arg#--directory=} ;; esac; done
case "$*" in *present*) mkdir -p "$dir" && : > "$dir/msvcp140.dll_x86" ;; esac
exit 0
EOF
chmod +x "$work/bin/cabextract"
mkdir -p "$work/cab/present" "$work/cab/absent" "$work/sys/present" "$work/sys/absent"
run() { env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" LANG=C "$@"; }

# 1. The version is upstream's (after an "Executing cd" line of its own).
out=$(run bash "$T" --version 2>&1) || fail "--version exited non-zero: $out"
if line=$(printf '%s\n' "$out" | grep '^20260125 - sha256sum: '); then
  echo "version: $line"
else
  fail "--version printed: $out"
fi

# 2. The verbs the app uses are there; the dropped ones are not.
run bash "$T" list-all > "$work/list.txt" 2>&1 || fail "list-all exited non-zero: $(tail -5 "$work/list.txt")"
for verb in vcrun2022 vcrun2019 vcrun2013 vcrun2010 vcrun2008 d3dcompiler_47 d3dx9 d3dx9_43 dotnet48 \
    dotnetdesktop6 corefonts cjkfonts xact xinput mf physx dsound dxvk powershell_core; do
  grep -q "^$verb " "$work/list.txt" || fail "list-all lacks $verb"
done
for verb in galliumnine galliumnine02 galliumnine010 ie7 ie8 ie8_kb2936068 ie8_tls12 otvdm otvdm090 powershell; do
  if grep -q "^$verb " "$work/list.txt"; then fail "list-all still offers $verb"; fi
done
echo "list-all: $(grep -c '^[a-z0-9_]* ' "$work/list.txt") verbs"

# 3. Sourced as a library: the default cache, and the network paths do nothing.
# (Read as a library, each verb's metadata has no folder to go to yet: that
# noise goes to lib.err, shown only if a check fails.)
cat > "$work/lib.sh" << 'EOF'
. "$1"
_W_ano_not_needed=1
unset W_CACHE XDG_CACHE_HOME
anotricks_init
echo "cache=$W_CACHE"
anotricks_latest_version_check
ANOTRICKS_STATS_REPORT=1 anotricks_stats_report
(anotricks_selfupdate) > /dev/null 2>&1 && echo "self-update returned 0"
(anotricks_selfupdate_rollback) > /dev/null 2>&1 && echo "rollback returned 0"
# The download-failure hint looked the user's country up at ipinfo.io.
anotricks_dl_warning
# vcrun2022's msvcp140.dll: copied whatever the cabinet calls it; none, the builtin stays.
w_ano_msvcp140 "$2/cab/present/a10" "$2/cab/present" "$2/sys/present" > /dev/null 2>&1 \
  && [ -f "$2/sys/present/msvcp140.dll" ] && echo "msvcp140: copied"
w_ano_msvcp140 "$2/cab/absent/a10" "$2/cab/absent" "$2/sys/absent" > /dev/null 2>&1 \
  && [ ! -e "$2/sys/absent/msvcp140.dll" ] && echo "msvcp140: builtin kept"
echo "library: done"
EOF
run ANOTRICKS_LIB=1 bash "$work/lib.sh" "$T" "$work" > "$work/lib.out" 2> "$work/lib.err" || true
cat "$work/lib.out"
grep -qx "library: done" "$work/lib.out" || fail "sourcing ano-tricks as a library did not finish: $(tail -5 "$work/lib.err")"
grep -qx "cache=$work/home/Library/Caches/io.github.highstormpvp.Ano/ano-tricks" "$work/lib.out" \
  || fail "the default cache is not Ano's cache folder"
if grep -q "returned 0" "$work/lib.out"; then fail "self-update or rollback did not refuse"; fi
grep -qx "msvcp140: copied" "$work/lib.out" || fail "w_ano_msvcp140 did not copy msvcp140.dll_x86"
grep -qx "msvcp140: builtin kept" "$work/lib.out" || fail "w_ano_msvcp140 failed when the cabinet lacks msvcp140"
if [ -s "$work/net.log" ]; then fail "reached for the network: $(cat "$work/net.log")"; fi

# 4. No link to a GitHub account named after ano-tricks (the rule's rename of
#    Winetricks/winetricks), no anohq, and the gate over the file.
if grep -Eni '(github\.com|githubusercontent\.com)/ano-?tricks|anohq' "$T"; then
  fail "a URL names a host or account Ano does not own"
fi
cp "$T" "$work/gate/"
"$PYTHON" "$HERE/wine_tokens.py" "$work/gate" --out "$work/tokens.tsv" \
  --allowlist "$HERE/wine-allowlist.txt" --gate || fail "the gate found wine tokens"

[ "$fails" -eq 0 ] || { echo "ano-tricks: $fails check(s) failed"; exit 1; }
echo "ano-tricks: all checks passed"
