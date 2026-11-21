#!/usr/bin/env bash
# Plan 3c-3 Task 2: the verbs the app uses, run with Libraries/ano-tricks in a
# bottle of engine 5.x, called the way the app calls it (Winetricks+Install.swift):
# one verb per call, `bash ano-tricks [--force] -q <verb>`, ANO=ano-loader found
# on PATH (the engine's bin, then the folder with cabextract), ANOSERVER,
# ANOPREFIX, HOME. Then remove_mono (dotnet48's first step) must find mono by
# its renamed name. Checks: each verb in the bottle's ano-tricks.log, the DLLs
# it installs native (not Ano's builtin stubs), its DLL overrides under
# Software\Ano, the downloads in Ano's cache folder and not ~/.cache, and the
# gate over the bottle.
# Usage: scripts/anowine/check-ano-tricks.sh <Libraries/Ano> <bottle>
set -Eeuo pipefail
trap 'echo "::error::check-ano-tricks.sh: line $LINENO: exit $?"' ERR
A=$(cd "${1:?usage: check-ano-tricks.sh <Libraries/Ano> <bottle>}" && pwd)
B=$(cd "${2:?usage: check-ano-tricks.sh <Libraries/Ano> <bottle>}" && pwd)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/scripts/anowine
T=$ROOT/Libraries/ano-tricks
CACHE=$HOME/Library/Caches/io.github.highstormpvp.Ano/ano-tricks
LOGS=${RUNNER_TEMP:-/tmp}/reports/ano-tricks  # uploaded with the job's reports
VERBS="vcrun2022 d3dcompiler_47 d3dx9 xact xinput"
fails=0
fail() { echo "::error::ano-tricks in a bottle: $*"; fails=$((fails + 1)); }

[ -f "$T" ] && [ -x "$ROOT/Libraries/cabextract" ] || { echo "::error::no $T or Libraries/cabextract"; exit 1; }
mkdir -p "$LOGS"
rm -rf "$HOME/.cache/winetricks" "$HOME/.cache/ano-tricks"
# On a CI runner each program takes seconds to reach a new server; one that
# stays up 60 s keeps a single boot per verb (as scan-wine-traces.sh does).
persistent_server() {
  "$A/bin/ano-server" -k 2> /dev/null || true
  ANOPREFIX="$B" "$A/bin/ano-server" -w 2> /dev/null || true
  ANOPREFIX="$B" "$A/bin/ano-server" -p60
}
run_verb() {  # verb, then the app's options
  local verb=$1 start code=0
  shift
  persistent_server
  start=$(date +%s)
  # The app's environment for an install (Winetricks+Install.swift), nothing more.
  perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 900 \
    env -i HOME="$HOME" ANOPREFIX="$B" ANO=ano-loader ANOSERVER="$A/bin/ano-server" \
    PATH="$A/bin:$ROOT/Libraries:/usr/bin:/bin" bash "$T" "$@" "$verb" > "$LOGS/$verb.log" 2>&1 || code=$?
  echo "$verb: exit $code after $(( $(date +%s) - start )) s"
  if [ "$code" != 0 ]; then
    tail -n 30 "$LOGS/$verb.log"
    fail "$verb exited $code$([ "$code" != 142 ] || echo ' (stopped after 900 s)')"
  fi
}

for verb in $VERBS; do
  case $verb in
    vcrun*) run_verb "$verb" --force -q ;;
    *) run_verb "$verb" -q ;;
  esac
done
run_verb remove_mono -q

# 0. A wrapper first on PATH, as the app's proxy puts its own ano-loader there
#    (ProxyEnvironment.swift), and no ANO_BIN: a script's architecture cannot be
#    read, so ano-tricks falls back to the loader's name, which must stay
#    ano-loader (renamed, upstream's fallback made it ano64-loader).
mkdir -p "$LOGS/wrapper"
printf '#!/bin/sh\nexec "%s/bin/ano-loader" "$@"\n' "$A" > "$LOGS/wrapper/ano-loader"
chmod +x "$LOGS/wrapper/ano-loader"
persistent_server
code=0
perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 300 \
  env -i HOME="$HOME" ANOPREFIX="$B" ANO=ano-loader ANOSERVER="$A/bin/ano-server" \
  PATH="$LOGS/wrapper:$A/bin:$ROOT/Libraries:/usr/bin:/bin" bash "$T" list-installed \
  > "$LOGS/wrapper.log" 2>&1 || code=$?
if [ "$code" != 0 ] || ! grep -qw vcrun2022 "$LOGS/wrapper.log"; then
  tail -n 20 "$LOGS/wrapper.log"
  fail "with a wrapper ano-loader first on PATH, list-installed failed (exit $code)"
else
  echo "wrapper first on PATH: list-installed works"
fi
"$A/bin/ano-server" -k 2> /dev/null || true

# 1. The log ano-tricks keeps in the bottle, under its new name.
[ ! -e "$B/winetricks.log" ] || fail "the bottle has winetricks.log"
for verb in $VERBS remove_mono; do
  grep -qx "$verb" "$B/ano-tricks.log" 2> /dev/null || fail "$verb is not in the bottle's ano-tricks.log"
done

# 2. What the verbs install is Microsoft's, not Ano's builtin stub.
#    (64-bit DLLs go to system32, 32-bit ones to syswow64; xact is 32-bit only.)
for file in system32/{msvcp140,vcruntime140,d3dcompiler_47,d3dx9_43,xinput1_3}.dll \
            syswow64/{msvcp140,vcruntime140,d3dcompiler_47,d3dx9_43,xinput1_3,xactengine3_7}.dll; do
  if [ ! -f "$B/drive_c/windows/$file" ]; then
    fail "no windows/$file"
  elif grep -q --text "Ano builtin DLL" "$B/drive_c/windows/$file"; then
    fail "windows/$file is still Ano's builtin stub"
  fi
done

# 3. Their DLL overrides are where the engine reads them: Software\Ano.
if grep -q 'Software\\\\Wine' "$B/user.reg" "$B/system.reg"; then fail "the registry has a Software\\Wine key"; fi
overrides=$(awk '/^\[Software\\\\Ano\\\\DllOverrides\]/ {on = 1; next} /^\[/ {on = 0} on' "$B/user.reg")
for dll in d3dx9_43 d3dcompiler_47 xinput1_3; do
  printf '%s\n' "$overrides" | grep -q "^\"\*\{0,1\}$dll\"=\"native" || fail "no native override for $dll under Software\\Ano\\DllOverrides"
done

# 4. Downloads in Ano's cache folder, nothing in ~/.cache.
[ -d "$CACHE/vcrun2022" ] || fail "no vcrun2022 download in $CACHE"
for old in "$HOME/.cache/winetricks" "$HOME/.cache/ano-tricks"; do
  [ ! -e "$old" ] || fail "$old exists"
done
if [ -d "$CACHE" ]; then echo "cache: $(du -sh "$CACHE" | cut -f1) in $CACHE: $(ls "$CACHE" | tr '\n' ' ')"; fi

# 5. remove_mono found mono by its renamed name.
mono=$(ANOPREFIX="$B" "$A/bin/ano-loader" uninstaller --list 2> /dev/null | grep -i "mono" || true)
"$A/bin/ano-server" -k 2> /dev/null || true
[ -z "$mono" ] || fail "mono is still installed after remove_mono: $mono"

# 6. The gate over the bottle, with what the verbs installed.
python3 "$HERE/wine_tokens.py" "$B" --allowlist "$HERE/wine-allowlist.txt" \
  --out "$LOGS/bottle-tokens.tsv" --gate || fail "the gate found wine tokens in the bottle"

[ "$fails" -eq 0 ] || { echo "ano-tricks in a bottle: $fails check(s) failed"; exit 1; }
echo "ano-tricks in a bottle: all checks passed"
