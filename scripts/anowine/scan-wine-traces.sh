#!/bin/bash
# Inventory of every trace of the word "wine" (any case) a bottle leaves on
# the Mac. Creates a bottle, runs programs and Wine tools, runs winetricks, and
# records:
#   - process names, command lines, environments and open files (polled)
#   - the Windows environment a program sees (cmd /c set)
#   - files created or changed outside the bottle (HOME, /tmp, TMPDIR), and
#     defaults domains, whose path or contents say wine
#   - inside the bottle: file names, file contents, symlinks and registry keys
#   - libraries loaded into Wine processes, shared memory and sockets
#   - how macOS registers the GUI processes (lsappinfo) and Mach services
#   - system and kernel extensions, launch agents and daemons, login items,
#     LaunchServices, the Rosetta translation cache, TCC, the system log
#   - the runtime's Mach-O files: signing identifiers, install names, linked
#     libraries, rpaths, embedded Info.plist; and the runtime's symlinks
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
      # command, FD (txt = a loaded library or program), type, name
      lsof -nP -c ano- 2>/dev/null | awk '{print $1, $4, $5, $NF}' >> "$OUT/raw-lsof.txt"
    fi
    if [ $((n % 20)) -eq 0 ]; then
      # How macOS registers the GUI processes (Dock, Cmd-Tab, Force Quit names)
      lsappinfo list 2>/dev/null | grep -iE -B1 -A8 'wine|ano-' >> "$OUT/raw-lsappinfo.txt"
      # Mach services Wine registers with launchd
      launchctl print "gui/$(id -u)" 2>/dev/null | grep -i wine >> "$OUT/raw-mach.txt"
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

# Machine-wide registrations, taken before and after so new entries stand out.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
system_state() {
  {
    echo "## system extensions"; systemextensionsctl list 2>&1
    echo "## kernel extensions"; kmutil showloaded --list-only 2>/dev/null || kextstat 2>/dev/null
    echo "## launch agents and daemons"
    ls -1 "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null
    echo "## launchd jobs"; launchctl list 2>/dev/null
    echo "## login and background items"; sudo -n sfltool dumpbtm 2>/dev/null
    echo "## LaunchServices"; "$LSREGISTER" -dump 2>/dev/null | grep -iE 'wine|ano-core|ano-loader'
    echo "## Rosetta translation cache"; sudo -n find /private/var/db/oah -iname '*wine*' 2>/dev/null
    echo "## TCC"; sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
      'select service, client from access' 2>/dev/null
  } > "$1"
}
system_state "$WORK/state-before.txt"
defaults domains 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | sort > "$WORK/domains-before.txt"
START="$(date '+%Y-%m-%d %H:%M:%S')"
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
# Winetricks runs many short Wine programs. On runtime 4.9.0 each one takes
# seconds to reach the server on a CI runner, after the server's 3 s idle exit,
# so every call would boot the prefix again. A server that stays up for 60 s
# after its last program keeps one boot for the whole step.
persistent_server() {
  "$BIN/ano-server" -k 2>/dev/null; "$BIN/ano-server" -w; "$BIN/ano-server" -p60
}
persistent_server
step "winetricks list-installed" 120 env WINE="$BIN/ano-loader" WINEARCH=win64 bash "$TRICKS" -q list-installed
persistent_server
step "winetricks win10 sound=disabled" 180 env WINE="$BIN/ano-loader" WINEARCH=win64 bash "$TRICKS" -q win10 sound=disabled
persistent_server
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

system_state "$WORK/state-after.txt"
cp "$WORK/state-before.txt" "$WORK/state-after.txt" "$OUT/" 2>/dev/null
section "System registrations (extensions, agents, login items, LaunchServices, Rosetta cache, TCC): lines with wine, after"
awk '/^## /{h=$0; next} tolower($0) ~ /wine/ {print h " | " $0}' "$WORK/state-after.txt" | sort -u | cap 60 >> "$R"; endsection
section "System registrations: lines that are new after the run"
# launchctl list rows (PID, status, label) change on their own; leave them out.
diff "$WORK/state-before.txt" "$WORK/state-after.txt" | grep '^>' | grep -vE '^> (-|[0-9]+)[[:space:]]+-?[0-9]+[[:space:]]' \
  | cap 60 >> "$R"; endsection

section "How macOS registers Wine's GUI processes (lsappinfo: name, bundle ID, paths)"
grep -iE 'name=|"[^"]*" ASN|bundleID|bundle path|executable path' "$OUT/raw-lsappinfo.txt" 2>/dev/null \
  | sed -E 's/ASN:[^ ]+//; s/^ +//' | sort | uniq -c | sort -rn | cap 40 >> "$R"; endsection
section "Mach services with wine in their name"
sed -E 's/^[[:space:]]+//' "$OUT/raw-mach.txt" 2>/dev/null | sort | uniq -c | sort -rn | cap 20 >> "$R"; endsection
section "Libraries and programs loaded into ano-* processes (lsof txt) whose name contains wine"
awk '$2 == "txt" {print $4}' "$OUT/raw-lsof.txt" 2>/dev/null | grep -i wine | sed -E 's#.*/##' | sort | uniq -c \
  | sort -rn | cap 60 >> "$R"; endsection
section "Shared memory, semaphores and sockets of ano-* processes (lsof PSXSHM/PSXSEM/unix)"
awk '$3 ~ /PSXSHM|PSXSEM|unix/ {print $3, $4}' "$OUT/raw-lsof.txt" 2>/dev/null \
  | sed -E 's#server-[0-9a-f]+-[0-9a-f]+#server-<dev>-<ino>#; s#0x[0-9a-f]+#<addr>#g' | sort | uniq -c | sort -rn \
  | cap 30 >> "$R"; endsection

section "System log entries mentioning wine since the scan started (count, then first 60)"
log show --start "$START" --style compact \
  --predicate 'process CONTAINS[c] "wine" OR process BEGINSWITH "ano-" OR subsystem CONTAINS[c] "winehq"' \
  2>/dev/null | grep -i wine > "$OUT/raw-syslog.txt"
echo "lines: $(wc -l < "$OUT/raw-syslog.txt" | tr -d ' ')" >> "$R"
sed -E 's/^[0-9-]+ [0-9:.]+ +//' "$OUT/raw-syslog.txt" | sort | uniq -c | sort -rn | cap 60 >> "$R"; endsection

section "Runtime Mach-O files: code-signing identifier, install name, linked libraries or embedded app info with wine"
find "$LIB" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) 2>/dev/null | while IFS= read -r f; do
  file -b "$f" | grep -q Mach-O || continue
  rel="${f#$LIB/}"
  id="$(codesign -dv "$f" 2>&1 | sed -n 's/^Identifier=//p')"
  case "$(echo "$id" | tr '[:upper:]' '[:lower:]')" in *wine*) echo "$rel | signing identifier: $id" ;; esac
  otool -D "$f" 2>/dev/null | tail -n +2 | grep -i wine | sed "s#^#$rel | install name: #"
  otool -L "$f" 2>/dev/null | tail -n +2 | grep -i wine | sed -E "s#^[[:space:]]+#$rel | links: #"
  otool -l "$f" 2>/dev/null | grep -A2 LC_RPATH | sed -n 's/^ *path //p' | grep -i wine | sed "s#^#$rel | rpath: #"
  launchctl plist __TEXT,__info_plist "$f" 2>/dev/null | grep -i wine | sed -E "s#^[[:space:]]+#$rel | embedded Info.plist: #"
done | cap 80 >> "$R"; endsection

section "Runtime symlinks (name -> target)"
find "$LIB" -type l 2>/dev/null | while IFS= read -r l; do echo "${l#$LIB/} -> $(readlink "$l")"; done | cap 40 >> "$R"
endsection
section "Outside the bottle: new symlinks (name -> target)"
while IFS= read -r l; do [ -L "$l" ] && echo "$l -> $(readlink "$l")"; done < "$OUT/raw-outside-changed.txt" | cap 40 >> "$R"
endsection

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

  section "Inside the bottle: every symlink (name -> target); wine in the name or target is marked !"
  find "$P" -type l 2>/dev/null | while IFS= read -r l; do
    t="$(readlink "$l")"; m=" "
    case "$(printf '%s %s' "$l" "$t" | tr '[:upper:]' '[:lower:]')" in *wine*) m="!" ;; esac
    echo "$m ${l#$P/} -> $t"
  done | sort | cap 60 >> "$R"; endsection

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

cp "$P"/*.reg "$OUT/" 2>/dev/null
( cd "$P" && find . -type f -o -type l ) 2>/dev/null | sort > "$OUT/raw-bottle-files.txt"
rm -rf "$WORK"
echo "report: $R"
exit 0
