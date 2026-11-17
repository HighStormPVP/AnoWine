#!/bin/bash
# Inventory of every trace of the word "wine" (any case) a bottle leaves on
# the Mac. Creates a bottle, runs programs and Wine tools, runs winetricks, and
# records:
#   - process names, command lines, environments and open files (polled)
#   - the Windows environment a program sees (cmd /c set)
#   - files created or changed outside the bottle (HOME, /tmp, TMPDIR), and
#     defaults domains, whose path or contents say wine
#   - inside the bottle: file names, file contents and registry keys
# An inventory, not a check: findings never fail it.
#
# Usage: scripts/anowine/scan-wine-traces.sh <Libraries-dir> <winetricks> <report-dir>
set -uo pipefail
LIB="$(cd "${1:?usage: scan-wine-traces.sh <Libraries-dir> <winetricks> <report-dir>}" && pwd)"
TRICKS="${2:?winetricks script}"
OUT="$(mkdir -p "${3:?report dir}" && cd "$3" && pwd)"
BIN="$LIB/Wine/bin"
WORK="$(mktemp -d /private/tmp/ano-scan.XXXXXX)"
P="$WORK/bottle"
# The per-user temp and cache folders (/private/var/folders/../T and ../C).
TMPROOT="$(dirname "$(cd "${TMPDIR:-/tmp}" && pwd -P)")"
export WINEPREFIX="$P" WINESERVER="$BIN/ano-server" WINEDEBUG=fixme-all

# ---- process poller ---------------------------------------------------------
poll() {
  local n=0
  while [ -f "$WORK/polling" ]; do
    ps -axww -o pid=,ppid=,ucomm=,command= >> "$OUT/raw-ps.txt" 2>/dev/null
    ps -axEww -o pid=,command= 2>/dev/null | grep -E "/ano-(core|loader|server)" >> "$OUT/raw-ps-env.txt"
    if [ $((n % 6)) -eq 0 ]; then
      lsof -nP -c ano- 2>/dev/null | awk '{print $1, $NF}' >> "$OUT/raw-lsof.txt"
    fi
    n=$((n + 1)); sleep 0.3
  done
}

# Runs one step with a time limit; GUI tools are closed when it runs out.
step() {
  local name="$1" limit="$2"; shift 2
  echo "== $name"
  echo "== $name" >> "$OUT/steps.txt"
  "$@" >> "$OUT/steps.txt" 2>&1 &
  local pid=$! t=0
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt "$limit" ]; do sleep 1; t=$((t + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "   (stopped after ${limit}s)" | tee -a "$OUT/steps.txt"
    kill "$pid" 2>/dev/null; "$BIN/ano-server" -k 2>/dev/null
  fi
  wait "$pid" 2>/dev/null; echo "   exit $?" | tee -a "$OUT/steps.txt"
}

defaults domains 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | sort > "$WORK/domains-before.txt"
touch "$WORK/polling"; touch "$WORK/marker"; sleep 1
poll &
POLLER=$!

step "create bottle (ano-boot --init)" 300 env WINEDLLOVERRIDES="mscoree,mshtml=" "$BIN/ano-loader" ano-boot --init
"$BIN/ano-server" -w
step "run a program (cmd /c set)" 120 sh -c '"$1/ano-loader" cmd /c set > "$2/windows-env.txt"' _ "$BIN" "$OUT"
step "run a program (reg query)" 60 "$BIN/ano-loader" reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion'
step "Wine tool: winecfg (closed after 15s)" 15 "$BIN/ano-loader" winecfg
step "Wine tool: regedit (closed after 15s)" 15 "$BIN/ano-loader" regedit
step "Wine tool: control (closed after 15s)" 15 "$BIN/ano-loader" control
"$BIN/ano-server" -k 2>/dev/null; "$BIN/ano-server" -w
step "winetricks list-installed" 120 env WINE="$BIN/ano-loader" WINEARCH=win64 bash "$TRICKS" -q list-installed
step "winetricks win10 sound=disabled" 180 env WINE="$BIN/ano-loader" WINEARCH=win64 bash "$TRICKS" -q win10 sound=disabled
step "winetricks vcrun2019 (download verb)" 420 env WINE="$BIN/ano-loader" WINEARCH=win64 bash "$TRICKS" -q vcrun2019
step "shut down" 60 "$BIN/ano-loader" ano-boot --shutdown
"$BIN/ano-server" -k 2>/dev/null; "$BIN/ano-server" -w
sleep 2
rm -f "$WORK/polling"; wait "$POLLER" 2>/dev/null

# ---- report -----------------------------------------------------------------
R="$OUT/report.md"
section() { printf '\n## %s\n\n```\n' "$1" >> "$R"; }
endsection() { printf '```\n' >> "$R"; }
cap() { head -n "${1:-80}"; }
: > "$R"
echo "# Wine traces" >> "$R"
echo "Runtime: $LIB (version $(/usr/libexec/PlistBuddy -c 'Print :version:patch' "$LIB/WhiskyWineVersion.plist" 2>/dev/null))" >> "$R"

section "Steps"
grep -E "^== |^   " "$OUT/steps.txt" >> "$R"; endsection

section "Process kernel names (ucomm) seen, Wine processes and anything named wine"
awk '{print $3}' "$OUT/raw-ps.txt" | sort | uniq -c | sort -rn \
  | grep -iE " (ano-|wine|winetricks|cabextract|start)" | cap >> "$R"; endsection

section "Process command lines containing wine (distinct)"
awk '{ $1=""; $2=""; sub(/^  /, ""); print }' "$OUT/raw-ps.txt" | grep -i wine \
  | grep -vE "scan-wine-traces|grep -i|ps -ax" | sort | uniq -c | sort -rn | cap 60 >> "$R"; endsection

section "Unix environment variables of Wine processes containing wine (name=value, distinct)"
tr ' ' '\n' < "$OUT/raw-ps-env.txt" | grep -E "^[A-Za-z_][A-Za-z0-9_]*=" | grep -i wine | sort | uniq -c | sort -rn | cap 60 >> "$R"; endsection

section "Windows environment seen by a program (cmd /c set), lines containing wine"
tr -d '\r' < "$OUT/windows-env.txt" 2>/dev/null | grep -i wine | cap >> "$R"; endsection

section "Open files and sockets of ano-* processes whose path contains wine (distinct)"
grep -i wine "$OUT/raw-lsof.txt" 2>/dev/null | sed -E 's#/private/tmp/ano-scan\.[^/]+#<work>#' | sort | uniq -c | sort -rn | cap 60 >> "$R"; endsection

# Files created or changed outside the bottle, the runtime and this scan.
find "$HOME" /private/tmp "$TMPROOT" /Users/Shared -xdev \
  \( -path "$WORK" -o -path "$LIB" -o -path "$OUT" -o -path "$HOME/work" -o -path "$HOME/actions-runner" \
     -o -path "$HOME/runners" -o -path "$HOME/hostedtoolcache" -o -path "$HOME/Library/Caches/com.apple.*" \) \
  -prune -o -newer "$WORK/marker" -print 2>/dev/null \
  | sort -u > "$OUT/raw-outside-changed.txt"
section "Outside the bottle: created or changed paths that contain wine"
grep -i wine "$OUT/raw-outside-changed.txt" | cap 80 >> "$R"; endsection
section "Outside the bottle: created or changed files whose contents contain wine"
while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -f %z "$f")" -lt 20000000 ] && grep -qai wine "$f" 2>/dev/null \
    && echo "$f ($(grep -oai wine "$f" | wc -l | tr -d ' ') matches)"
done < <(head -n 5000 "$OUT/raw-outside-changed.txt") | cap 80 >> "$R"; endsection
section "Outside the bottle: all created or changed paths (first 150)"
cap 150 < "$OUT/raw-outside-changed.txt" >> "$R"; endsection

defaults domains 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | sort > "$WORK/domains-after.txt"
section "New defaults domains"
comm -13 "$WORK/domains-before.txt" "$WORK/domains-after.txt" >> "$R"; endsection
section "launchd jobs containing wine"
launchctl list 2>/dev/null | grep -i wine >> "$R"; endsection

if [ -d "$P" ]; then
  section "Inside the bottle: paths whose name contains wine"
  find "$P" -iname '*wine*' 2>/dev/null | sed "s#^$P#<bottle>#" | sort > "$OUT/raw-bottle-names.txt"
  echo "total: $(wc -l < "$OUT/raw-bottle-names.txt" | tr -d ' ')" >> "$R"
  cap 120 < "$OUT/raw-bottle-names.txt" >> "$R"; endsection

  section "Inside the bottle: files whose contents contain wine, by folder"
  grep -rlai wine "$P" 2>/dev/null | sed "s#^$P#<bottle>#" | sort > "$OUT/raw-bottle-contents.txt"
  echo "total files: $(wc -l < "$OUT/raw-bottle-contents.txt" | tr -d ' ') of $(find "$P" -type f | wc -l | tr -d ' ')" >> "$R"
  sed -E 's#/[^/]+$##' "$OUT/raw-bottle-contents.txt" | sort | uniq -c | sort -rn | cap 40 >> "$R"; endsection

  section "Inside the bottle: the wine strings in one system32 placeholder (kernel32.dll)"
  LC_ALL=C grep -oai '[ -~]\{0,30\}wine[ -~]\{0,30\}' "$P/drive_c/windows/system32/kernel32.dll" 2>/dev/null | sort | uniq -c | cap 20 >> "$R"; endsection

  section "Inside the bottle: files outside windows/ whose contents contain wine"
  grep -v "^<bottle>/drive_c/windows/" "$OUT/raw-bottle-contents.txt" | cap 60 >> "$R"; endsection

  section "Registry: keys containing wine (system.reg, user.reg, userdef.reg)"
  for reg in system.reg user.reg userdef.reg; do
    [ -f "$P/$reg" ] || continue
    echo "-- $reg: $(grep -ci wine "$P/$reg") lines mention wine, $(grep -ciE '^\[.*wine' "$P/$reg") keys"
    grep -iE '^\[.*wine' "$P/$reg" | sed -E 's/\] [0-9]+$/]/' | cap 50
  done >> "$R"; endsection

  section "Registry: values (not keys) containing wine, first 60"
  for reg in system.reg user.reg userdef.reg; do
    [ -f "$P/$reg" ] && grep -iE '^[@"].*wine' "$P/$reg" | sed "s#^#$reg: #"
  done | cap 60 >> "$R"; endsection
fi

cp -R "$P/drive_c/users" "$OUT/bottle-users" 2>/dev/null
cp "$P"/*.reg "$OUT/" 2>/dev/null
( cd "$P" && find . -type f -o -type l ) 2>/dev/null | sort > "$OUT/raw-bottle-files.txt"
rm -rf "$WORK"
echo "report: $R"
exit 0
