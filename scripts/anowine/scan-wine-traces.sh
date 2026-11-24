#!/bin/bash
# scan-wine-traces.sh: the Mac-state gate for engine 5.x (Plan 3c-5, Task 3).
#
# It drives the engine through a short session with a persistent server
# (ano-server -p60): a new bottle (ano-boot --init), a console program
# (cmd /c set, which prints the Windows environment), the GUI tools ano-cfg,
# regedit and notepad for a few seconds each (then killed by PID), and the
# ano-tricks verb win10. It captures, as text in <report-dir>/gate/, only what
# is new since the session started:
#   processes.txt     command lines of the engine's processes: a command that
#                     contains <Libraries>/Ano/ or the work folder, or a name
#                     that starts with ano- (ps, polled)
#   environments.txt  their environments (ps -E)
#   windows-env.txt   the Windows environment (cmd /c set)
#   open-files.txt    their open files (lsof -c ano-, polled)
#   outside/          files created or changed under HOME, the temporary and
#                     cache folders, /private/tmp and the runtime folder,
#                     outside the bottle, copied with their relative paths up
#                     to 5 MB each; outside-paths.txt names every one and
#                     outside-large.txt those too large to copy
#   defaults/         new defaults domains with their contents
#   launchd-list.txt, launchd-gui.txt, lsappinfo.txt, launchservices.txt:
#                     new lines in launchctl list, launchctl print gui/<uid>,
#                     lsappinfo list and the LaunchServices dump
#   rosetta.txt       new files in the Rosetta cache, by name
#   syslog.txt        the system log since the start: the engine's processes
#                     (ano-*) and every line that says wine
#   output/           what the session's programs printed (the app logs it)
# The judge is wine_tokens.py <report-dir>/gate <bottle> --gate with
# wine-allowlist.txt.
#
# No captured path or variable may carry the harness's: the session runs in a
# work folder under /private/tmp from copies of its inputs, the engine gets
# only the variables the app gives it (WineEnvironment.swift builds a fixed
# dictionary, never the app's own environment), and this script re-runs
# itself with a clean environment so no runner variable (GITHUB_*, RUNNER_*)
# reaches anything it starts. The CI runner's own folders (its work root and
# tool cache) are not Mac state an Ano user has, and the file capture skips
# them; the runtime folder is captured on its own.
#
# Usage: scan-wine-traces.sh <Libraries> <ano-tricks> <report-dir> [--app <Ano.app>] [--plant]
# Exit 0: the gate passes. Exit 1: a token not on the allowlist;
# <report-dir>/traces.md lists each token and where it was seen. Exit 2: a
# harness error, such as a step that never started or an empty capture where
# one cannot be empty.
# --plant is the self-test: the session also starts a console program with
# PLANTWINE=1 in its environment, creates ~/.cache/plantwine/x and logs
# "plantwine". It exits 1 when the gate lists exactly PLANTWINE and plantwine,
# each found by its own capture (processes, files, system log), else 2.
# --app <Ano.app> is Plan 3c-5 Task 4 (not built yet: exit 2).
set -Eeuo pipefail
trap 'echo "::error::scan-wine-traces.sh: line $LINENO: exit $?"; exit 2' ERR
USAGE="usage: scan-wine-traces.sh <Libraries> <ano-tricks> <report-dir> [--app <Ano.app>] [--plant]"

# A clean environment for everything this script starts. Only the CI runner's
# work root and tool cache are passed on, to be left out of the file capture.
if [ "${ANO_GATE_CLEAN:-}" != 1 ]; then
  runner_dirs=
  [ -z "${RUNNER_WORKSPACE:-}" ] || runner_dirs="$runner_dirs:$(dirname "$RUNNER_WORKSPACE")"
  [ -z "${RUNNER_TOOL_CACHE:-}" ] || runner_dirs="$runner_dirs:$RUNNER_TOOL_CACHE"
  me=$(id -un)
  exec env -i ANO_GATE_CLEAN=1 ANO_GATE_RUNNER_DIRS="${runner_dirs#:}" HOME="$HOME" USER="$me" LOGNAME="$me" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin LC_ALL=C /bin/bash "$0" "$@"
fi

harness() { echo "::error::scan-wine-traces.sh: $*"; exit 2; }
[ $# -ge 3 ] || harness "$USAGE"
LIB_ARG=$1 TRICKS_ARG=$2 OUT_ARG=$3
shift 3
PLANT=0 APP=
while [ $# -gt 0 ]; do
  case $1 in
    --plant) PLANT=1 ;;
    --app) [ $# -ge 2 ] || harness "$USAGE"; APP=$2; shift ;;
    *) harness "$USAGE" ;;
  esac
  shift
done
[ -z "$APP" ] || harness "--app is not built yet (Plan 3c-5, Task 4)"

HERE=$(cd "$(dirname "$0")" && pwd -P)
LIB=$(cd "$LIB_ARG" 2> /dev/null && pwd -P) || harness "no folder $LIB_ARG"
A=$LIB/Ano
[ -x "$A/bin/ano-loader" ] && [ -x "$A/bin/ano-server" ] && [ -f "$LIB/AnoRuntimeVersion.plist" ] \
  || harness "$LIB is not an engine 5.x Libraries folder (Ano/bin/ano-loader, AnoRuntimeVersion.plist)"
[ -f "$TRICKS_ARG" ] || harness "no ano-tricks at $TRICKS_ARG"
mkdir -p "$OUT_ARG"
OUT=$(cd "$OUT_ARG" && pwd -P)
G=$OUT/gate
RAW=$OUT/raw
rm -rf "$G" "$RAW" "$OUT/tokens.tsv" "$OUT/judge.txt" "$OUT/traces.md" "$OUT/bottle"
mkdir -p "$G/output" "$G/outside" "$G/defaults" "$RAW" "$OUT/bottle"
: > "$RAW/problems.txt"
problem() { echo "::error::scan-wine-traces.sh: $*"; echo "$*" >> "$RAW/problems.txt"; }

for tool in python3 perl lsof lsappinfo launchctl log logger defaults getconf; do
  command -v "$tool" > /dev/null || harness "no $tool on PATH"
done
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] || harness "no lsregister at $LSREGISTER"
sudo -n true 2> /dev/null || harness "sudo -n does not work, so the Rosetta cache cannot be read"
sudo -n test -d /private/var/db/oah || harness "no Rosetta cache at /private/var/db/oah (is Rosetta installed?)"
UIDN=$(id -u)
USER_TMP=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
USER_CACHE=$(cd "$(getconf DARWIN_USER_CACHE_DIR)" && pwd -P)

# The work folder: the bottle and copies of the inputs. Everything runs from
# here, so no process's working folder is the checkout.
WORK=$(cd "$(mktemp -d /private/tmp/ano-gate.XXXXXX)" && pwd -P)
P=$WORK/bottle
mkdir -p "$WORK/tools"
cp "$TRICKS_ARG" "$WORK/tools/ano-tricks"
TRICKS=$WORK/tools/ano-tricks
cd "$WORK"

# What the app gives the engine (WineEnvironment.swift, base and platform
# layers): ANOPREFIX, ANOSERVER, ANODEBUG, GST_DEBUG, and ANOESYNC on macOS
# 15.4 and later. ano-dbg is off, as in the engine checks, so a crash cannot
# leave a dialog waiting on the runner.
SESSION_ENV=(ANOPREFIX="$P" ANOSERVER="$A/bin/ano-server" ANODEBUG=fixme-all GST_DEBUG=1 ANOESYNC=1
  ANODLLOVERRIDES=ano-dbg.exe=d)
# What the app gives ano-tricks (Winetricks+Install.swift), as check-ano-tricks.sh runs it.
TRICKS_ENV=(HOME="$HOME" ANOPREFIX="$P" ANO=ano-loader ANOSERVER="$A/bin/ano-server" PATH="$A/bin:/usr/bin:/bin")
limit() { perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$@"; }  # seconds, command...
engine() { env -i "${SESSION_ENV[@]}" "$@"; }
phase() { echo "== $(date '+%H:%M:%S') $*"; }
# The engine's processes now, for a wait that ran out. The pattern is read
# from a file, so this grep's own command line is not an engine process's.
printf '%s\n' "$A/" > "$RAW/engine-pattern"
engine_processes() {
  ps -axww -o pid=,ppid=,ucomm=,command= > "$RAW/ps-now.txt" 2> /dev/null || true
  grep -F -f "$RAW/engine-pattern" "$RAW/ps-now.txt" | cut -c1-240 || true
}
server() {  # -k or -w: stop the bottle's server, or wait for it to exit (at most 120 s)
  local code=0
  limit 120 env -i "${SESSION_ENV[@]}" "$A/bin/ano-server" "$1" > /dev/null 2>&1 || code=$?
  if [ "$code" = 142 ]; then
    echo "   ano-server $1 still waiting after 120 s; the engine's processes:"
    engine_processes
  fi
}

CACHE_EXISTED=0
[ ! -d "$HOME/.cache" ] || CACHE_EXISTED=1
POLLER=
cleanup() {
  local code=$?
  trap - ERR
  set +e
  rm -f "$RAW/polling"
  [ -z "$POLLER" ] || wait "$POLLER" 2> /dev/null
  limit 60 env -i "${SESSION_ENV[@]}" "$A/bin/ano-server" -k > /dev/null 2>&1
  if [ "$PLANT" = 1 ]; then
    rm -rf "$HOME/.cache/plantwine"
    [ "$CACHE_EXISTED" = 1 ] || rmdir "$HOME/.cache" 2> /dev/null
  fi
  rm -rf "$WORK"
  exit "$code"
}
trap cleanup EXIT

# ---- before -------------------------------------------------------------------
phase "before: launchd, lsappinfo, LaunchServices, defaults domains"
launchctl list > "$RAW/launchd-list-before.txt" 2> /dev/null || true
launchctl print "gui/$UIDN" > "$RAW/launchd-gui-before.txt" 2> /dev/null || true
lsappinfo list > "$RAW/lsappinfo-before.txt" 2> /dev/null || true
"$LSREGISTER" -dump > "$RAW/launchservices-before.txt" 2> /dev/null || true
defaults domains 2> /dev/null | tr ',' '\n' | sed 's/^ *//' | sort -u > "$RAW/domains-before.txt" || true
for f in launchd-list launchd-gui lsappinfo launchservices; do
  [ -s "$RAW/$f-before.txt" ] || harness "the $f snapshot before the session is empty, so nothing new could be told"
done
[ -s "$RAW/domains-before.txt" ] || harness "defaults domains printed nothing"

ps -axo pid= > "$RAW/pids-before.txt"
START=$(date '+%Y-%m-%d %H:%M:%S')
MARK=$RAW/marker
touch "$MARK"
sleep 1
LOGMARK="ano-gate-session-$(date +%s)-$$"
logger "$LOGMARK start"

# ---- the poller: engine processes, their environments and open files, and
# what launchd and lsappinfo list while the session runs ------------------------
for f in ps ps-env lsof lsappinfo-during launchd-list-during launchd-gui-during; do : > "$RAW/$f.txt"; done
poll() {
  local me n=0 pids
  sh -c 'echo $PPID' > "$RAW/poller.pid"
  read -r me < "$RAW/poller.pid"
  while [ -f "$RAW/polling" ]; do
    # The poller and the programs it starts are the harness, not the session.
    ps -axww -o pid=,ppid=,ucomm=,command= 2> /dev/null \
      | awk -v me="$me" -v lib="$A/" -v work="$WORK" '
          FNR == NR { old[$1] = 1; next }
          ($1 in old) || $1 == me || $2 == me { next }
          index($0, lib) || index($0, work) || $3 ~ /^ano-/ { print }' "$RAW/pids-before.txt" - \
      > "$RAW/now.txt" 2> /dev/null || true
    if [ -s "$RAW/now.txt" ]; then
      cat "$RAW/now.txt" >> "$RAW/ps.txt" || true
      pids=$(awk '{ printf "%s%s", s, $1; s = "," }' "$RAW/now.txt") || true
      ps -Eww -o pid=,command= -p "$pids" >> "$RAW/ps-env.txt" 2> /dev/null || true
    fi
    if [ $((n % 6)) -eq 0 ]; then
      lsof -nP -c ano- -F pcftn >> "$RAW/lsof.txt" 2> /dev/null || true
    fi
    if [ $((n % 10)) -eq 0 ]; then
      lsappinfo list >> "$RAW/lsappinfo-during.txt" 2> /dev/null || true
      launchctl list >> "$RAW/launchd-list-during.txt" 2> /dev/null || true
      launchctl print "gui/$UIDN" >> "$RAW/launchd-gui-during.txt" 2> /dev/null || true
    fi
    n=$((n + 1))
    sleep 0.5
  done
}
touch "$RAW/polling"
poll &
POLLER=$!

# ---- the session ----------------------------------------------------------------
phase "create a bottle (ano-boot --init)"
code=0
limit 600 env -i "${SESSION_ENV[@]}" "$A/bin/ano-loader" ano-boot --init > "$G/output/boot.txt" 2>&1 || code=$?
echo "   exit $code"
server -w
if [ "$code" != 0 ] || [ ! -f "$P/system.reg" ]; then
  tail -n 30 "$G/output/boot.txt" || true
  engine_processes
  harness "ano-boot --init exited $code$([ "$code" != 142 ] || echo ' (stopped after 600 s)'); no bottle"
fi

# One server for the rest of the session: on a CI runner a new one boots the
# bottle again for every program.
server -k
engine "$A/bin/ano-server" -p60 < /dev/null > /dev/null 2>&1

phase "a console program (cmd /c set)"
code=0
limit 300 env -i "${SESSION_ENV[@]}" "$A/bin/ano-loader" cmd /c set > "$RAW/windows-env.crlf" \
  2> "$G/output/cmd-set.txt" || code=$?
tr -d '\r' < "$RAW/windows-env.crlf" > "$G/windows-env.txt"
echo "   exit $code, $(wc -l < "$G/windows-env.txt" | tr -d ' ') variables"
grep -qi '^windir=' "$G/windows-env.txt" || problem "cmd /c set printed no Windows environment (exit $code)"

if [ "$PLANT" = 1 ]; then
  phase "plant: PLANTWINE=1 in a console program's environment, ~/.cache/plantwine/x, a log line"
  mkdir -p "$HOME/.cache/plantwine"
  : > "$HOME/.cache/plantwine/x"
  logger "plantwine"
  # pause waits on its input until the pipe closes, so the program stays up
  # while the poller looks.
  code=0
  { sleep 10; } | limit 120 env -i "${SESSION_ENV[@]}" PLANTWINE=1 "$A/bin/ano-loader" cmd /c pause \
    > "$RAW/plant.txt" 2>&1 || code=$?
  echo "   exit $code"
fi

gui_tool() {  # program, seconds: open it, then kill it by PID
  local tool=$1 secs=$2 pid t=0
  phase "$tool (open for ${secs} s)"
  env -i "${SESSION_ENV[@]}" "$A/bin/ano-loader" "$tool" > "$G/output/$tool.txt" 2>&1 &
  pid=$!
  while [ "$t" -lt "$secs" ] && kill -0 "$pid" 2> /dev/null; do sleep 1; t=$((t + 1)); done
  if kill -0 "$pid" 2> /dev/null; then
    kill -TERM "$pid" 2> /dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
    kill -KILL "$pid" 2> /dev/null || true
    echo "   killed after ${secs} s"
  else
    echo "   ended by itself after ${t} s"
  fi
  wait "$pid" 2> /dev/null || true
}
for tool in ano-cfg regedit notepad; do gui_tool "$tool" 20; done

phase "ano-tricks win10"
# The verb runs ano-server -w itself, so it waits out the persistent server.
server -k
server -w
engine "$A/bin/ano-server" -p60 < /dev/null > /dev/null 2>&1
code=0
limit 600 env -i "${TRICKS_ENV[@]}" /bin/bash "$TRICKS" -q win10 > "$G/output/ano-tricks-win10.txt" 2>&1 || code=$?
echo "   exit $code"
if [ "$code" != 0 ] || ! grep -qx win10 "$P/ano-tricks.log" 2> /dev/null; then
  tail -n 20 "$G/output/ano-tricks-win10.txt" || true
  engine_processes
  problem "ano-tricks win10 exited $code$([ "$code" != 142 ] || echo ' (stopped after 600 s)')" \
    "or is not in the bottle's ano-tricks.log"
fi

phase "shut down"
server -k
server -w
sleep 3
rm -f "$RAW/polling"
wait "$POLLER" || true
POLLER=

# ---- captures -------------------------------------------------------------------
phase "captures"
awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }' "$RAW/ps.txt" | sort -u > "$G/processes.txt"
awk '{ $1 = ""; sub(/^ +/, ""); print }' "$RAW/ps-env.txt" | sort -u > "$G/environments.txt"
awk 'FNR == NR { old[$1] = 1; next }
     /^p/ { pid = substr($0, 2); skip = (pid in old); next }
     /^c/ { cmd = substr($0, 2); next }
     /^f/ { fd = substr($0, 2); type = ""; next }
     /^t/ { type = substr($0, 2); next }
     /^n/ && !skip { print cmd " " fd " " type " " substr($0, 2) }' "$RAW/pids-before.txt" "$RAW/lsof.txt" \
  | sort -u > "$G/open-files.txt"

[ -s "$G/processes.txt" ] || problem "no engine process was seen (ps)"
# An engine program's line (it starts with the engine's path) whose words
# after it hold the value: a variable, not env -i's arguments.
engine_line_has() {  # file, text, [text]
  awk -v a="$A/" -v t1="$2" -v t2="${3:-}" '
    index($0, a) == 1 && index($0, t1) && (t2 == "" || index($0, t2)) { found = 1 }
    END { exit !found }' "$1"
}
engine_line_has "$G/environments.txt" "ANOPREFIX=$P" \
  || problem "ps -E showed no engine process with ANOPREFIX=$P, so the environments were not captured"
grep -qF "$A/" "$G/open-files.txt" || problem "lsof -c ano- showed no file of the engine, so open files were not captured"
for tool in ano-cfg regedit notepad; do
  grep -qE "ano-loader $tool( |\$)" "$G/processes.txt" || problem "$tool was never seen running"
done
grep -qF "bin/ano-loader ano-boot --init" "$G/processes.txt" || problem "ano-boot was never seen running"
grep -qF "$TRICKS -q win10" "$G/processes.txt" || problem "ano-tricks was never seen running"

# New lines in what launchd, lsappinfo and LaunchServices list.
new_lines() {  # out, before, after...
  local out=$1 before=$2
  shift 2
  sort -u "$@" | comm -13 "$before.sorted" - > "$out"
}
launchctl list > "$RAW/launchd-list-after.txt" 2> /dev/null || true
launchctl print "gui/$UIDN" > "$RAW/launchd-gui-after.txt" 2> /dev/null || true
lsappinfo list > "$RAW/lsappinfo-after.txt" 2> /dev/null || true
"$LSREGISTER" -dump > "$RAW/launchservices-after.txt" 2> /dev/null || true
for f in launchd-list launchd-gui lsappinfo launchservices; do
  sort -u "$RAW/$f-before.txt" > "$RAW/$f-before.txt.sorted"
done
new_lines "$G/launchd-list.txt" "$RAW/launchd-list-before.txt" "$RAW/launchd-list-during.txt" "$RAW/launchd-list-after.txt"
new_lines "$G/launchd-gui.txt" "$RAW/launchd-gui-before.txt" "$RAW/launchd-gui-during.txt" "$RAW/launchd-gui-after.txt"
new_lines "$G/lsappinfo.txt" "$RAW/lsappinfo-before.txt" "$RAW/lsappinfo-during.txt" "$RAW/lsappinfo-after.txt"
new_lines "$G/launchservices.txt" "$RAW/launchservices-before.txt" "$RAW/launchservices-after.txt"
rm -f "$RAW"/launchservices-*.txt*

# New defaults domains, with their contents.
defaults domains 2> /dev/null | tr ',' '\n' | sed 's/^ *//' | sort -u > "$RAW/domains-after.txt" || true
comm -13 "$RAW/domains-before.txt" "$RAW/domains-after.txt" > "$G/defaults-domains.txt"
while IFS= read -r domain; do
  [ -n "$domain" ] || continue
  defaults read "$domain" > "$G/defaults/$domain.txt" 2>&1 || true
done < "$G/defaults-domains.txt"

# Files created or changed outside the bottle. A folder counts when it was
# created after the start; a file or link when it was created or changed.
prune=(-path "$OUT" -o -path "$P")
IFS=: read -r -a runner_dirs <<< "${ANO_GATE_RUNNER_DIRS:-}"
for d in ${runner_dirs[@]+"${runner_dirs[@]}"}; do
  if [ -d "$d" ]; then prune+=(-o -path "$(cd "$d" && pwd -P)"); fi
done
: > "$G/outside-paths.txt"
: > "$G/outside-large.txt"
: > "$RAW/outside-unreadable.txt"
capture_outside() {  # label, root
  local label=$1 root=$2 f rel dest size
  find "$root" -xdev \( "${prune[@]}" \) -prune -o \
    \( \( -type d -newerBm "$MARK" \) -o \( ! -type d -newer "$MARK" \) \) -print 2> /dev/null \
    | LC_ALL=C sort > "$RAW/outside-$label.txt" || true
  while IFS= read -r f; do
    [ "$f" != "$root" ] || continue
    echo "$f" >> "$G/outside-paths.txt"
    rel=${f#"$root"/}
    dest=$G/outside/$label/$rel
    if [ -L "$f" ]; then
      mkdir -p "$(dirname "$dest")" && ln -sfn "$(readlink "$f")" "$dest" || echo "$f" >> "$RAW/outside-unreadable.txt"
    elif [ -d "$f" ]; then
      mkdir -p "$dest" || true
    elif [ -f "$f" ]; then
      size=$(stat -f %z "$f" 2> /dev/null) || continue
      if [ "$size" -gt 5242880 ]; then
        echo "$f ($size bytes)" >> "$G/outside-large.txt"
      else
        mkdir -p "$(dirname "$dest")" && cp "$f" "$dest" 2> /dev/null || echo "$f" >> "$RAW/outside-unreadable.txt"
      fi
    fi
  done < "$RAW/outside-$label.txt"
}
capture_outside home "$HOME"
capture_outside tmp /private/tmp
capture_outside temp "$USER_TMP"
capture_outside cache "$USER_CACHE"
capture_outside runtime "$LIB"
[ -s "$G/outside-paths.txt" ] || problem "no file was created or changed outside the bottle, not even the server's folder"
if [ "$PLANT" = 1 ]; then
  grep -qxF "$HOME/.cache/plantwine/x" "$G/outside-paths.txt" || problem "the file capture missed ~/.cache/plantwine/x"
fi

# New files in the Rosetta cache, by name.
sudo -n find /private/var/db/oah -newer "$MARK" ! -type d 2> /dev/null | sort > "$G/rosetta.txt" || true

# The system log since the start: the engine's processes and every line that
# says wine. The start line this script logged proves the window is right.
PREDICATE="process BEGINSWITH \"ano-\" OR process CONTAINS[c] \"wine\" OR sender CONTAINS[c] \"wine\""
PREDICATE="$PREDICATE OR subsystem CONTAINS[c] \"wine\" OR category CONTAINS[c] \"wine\""
PREDICATE="$PREDICATE OR eventMessage CONTAINS[c] \"wine\" OR eventMessage CONTAINS \"$LOGMARK\""
log show --start "$START" --info --style compact --predicate "$PREDICATE" > "$G/syslog.txt" 2> "$RAW/syslog.err" \
  || problem "log show failed: $(head -c 300 "$RAW/syslog.err")"
grep -qF "$LOGMARK start" "$G/syslog.txt" \
  || problem "the system log capture misses the line logged at the start ($START), so its window is wrong"

cp "$P"/*.reg "$P/ano-tricks.log" "$OUT/bottle/" 2> /dev/null || true

# ---- the judge ------------------------------------------------------------------
phase "the judge: wine_tokens.py gate bottle --gate"
judge=0
python3 "$HERE/wine_tokens.py" "$G" "$P" --allowlist "$HERE/wine-allowlist.txt" --out "$OUT/tokens.tsv" --gate \
  > "$OUT/judge.txt" 2>&1 || judge=$?
cat "$OUT/judge.txt"
case $judge in 0 | 1) ;; *) problem "wine_tokens.py exited $judge" ;; esac

if [ "$PLANT" = 1 ] && [ ! -s "$RAW/problems.txt" ]; then
  listed=$(awk -F'\t' 'NR > 1 && $2 !~ /^allowlisted/ { print $1 }' "$OUT/tokens.tsv" | sort | tr '\n' ' ')
  [ "$judge" = 1 ] || problem "the planted run: the gate exited $judge, not 1"
  [ "$listed" = "PLANTWINE plantwine " ] || problem "the planted run listed '$listed', not exactly 'PLANTWINE plantwine'"
  engine_line_has "$G/environments.txt" "cmd /c pause " "PLANTWINE=1" \
    || problem "the process capture missed PLANTWINE=1 in the planted program's environment"
  grep -qF "plantwine" "$G/syslog.txt" || problem "the system log capture missed the plantwine line"
fi

# ---- the report -----------------------------------------------------------------
if [ -s "$RAW/problems.txt" ]; then
  verdict="harness error (exit 2)"
elif [ "$PLANT" = 1 ]; then
  verdict="self-test passed: the gate listed exactly the planted tokens (exit 1)"
elif [ "$judge" = 0 ]; then
  verdict="pass: every token is on the allowlist (exit 0)"
else
  verdict="fail: tokens not on the allowlist (exit 1)"
fi
count() { if [ -e "$1" ]; then wc -l < "$1" | tr -d ' '; else echo "-"; fi; }
{
  echo "# Mac-state gate"
  echo
  echo "- runtime: $LIB"
  echo "- mode: $([ "$PLANT" = 1 ] && echo 'self-test (--plant)' || echo gate)"
  echo "- verdict: $verdict"
  echo
  if [ -s "$RAW/problems.txt" ]; then
    echo "## Harness errors"
    echo
    sed 's/^/- /' "$RAW/problems.txt"
    echo
  fi
  echo "## Captures (gate/)"
  echo
  echo "| capture | lines |"
  echo "|---|---|"
  for f in processes environments windows-env open-files outside-paths outside-large launchd-list launchd-gui \
           lsappinfo launchservices defaults-domains rosetta syslog; do
    echo "| $f.txt | $(count "$G/$f.txt") |"
  done
  echo "| outside/ | $(find "$G/outside" -type f | wc -l | tr -d ' ') files copied," \
    "$(count "$RAW/outside-unreadable.txt") unreadable |"
  echo
  echo "## Tokens not on the allowlist"
  echo
  awk -F'\t' 'NR > 1 && $2 !~ /^allowlisted/' "$OUT/tokens.tsv" 2> /dev/null > "$RAW/hits.tsv" || true
  [ -s "$RAW/hits.tsv" ] || echo "none"
  while IFS=$'\t' read -r token class n files example; do
    echo "### $token"
    echo
    echo "$n occurrences in $files files ($class); first in $example"
    echo
    { find "$G" "$P" -name "*$token*" 2> /dev/null || true; } | head -n 10 | sed "s#^$OUT/##; s#^$P#bottle#; s/^/- name: /" || true
    { grep -rlaF -- "$token" "$G" "$P" 2> /dev/null || true; } | head -n 10 \
      | sed "s#^$OUT/##; s#^$P#bottle#; s/^/- in: /" || true
    { grep -rhaoE -- ".{0,80}$token.{0,80}" "$G" 2> /dev/null || true; } | head -n 5 | sed 's/^/    /' || true
    echo
  done < "$RAW/hits.tsv"
} > "$OUT/traces.md"
echo "verdict: $verdict"

[ ! -s "$RAW/problems.txt" ] || exit 2
[ "$PLANT" = 0 ] || exit 1
exit "$judge"
