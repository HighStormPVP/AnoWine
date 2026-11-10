#!/bin/bash
# Fails unless an unpacked runtime has wineboot.exe renamed ano-boot.exe and
# winedevice.exe renamed ano-device.exe, with nothing left that starts them by
# their old names, and both still doing their jobs.
#
# Usage: scripts/anowine/check-ano-programs.sh <Libraries-dir> [options]
#   --boot                   create a bottle; check both programs ran and a driver
#                            is hosted (MountMgr running)
#   --exitwindows <exe>      run a test program that calls user32 ExitWindowsEx,
#                            which must start ano-boot.exe
#   --upgrade-from <Libs>    make a bottle with an older runtime, then open it with
#                            this one; the bottle must update and keep working
#   --winetricks <script>    create a bottle through winetricks (WINEARCH set)
set -uo pipefail
LIB="$(cd "${1:?usage: check-ano-programs.sh <Libraries-dir> [options]}" && pwd)"
shift
BOOT=0 EXITWIN="" OLD="" WINETRICKS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --boot) BOOT=1 ;;
    --exitwindows) EXITWIN="$2"; shift ;;
    --upgrade-from) OLD="$(cd "$2" && pwd)"; shift ;;
    --winetricks) WINETRICKS="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
WINE="$LIB/Wine"
BIN="$WINE/bin"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== runtime files"
check "x86_64-windows/ano-boot.exe exists" '[ -f "$WINE/lib/wine/x86_64-windows/ano-boot.exe" ]'
check "x86_64-windows/ano-device.exe exists" '[ -f "$WINE/lib/wine/x86_64-windows/ano-device.exe" ]'
check "i386-windows/ano-device.exe exists" '[ -f "$WINE/lib/wine/i386-windows/ano-device.exe" ]'
check "no wineboot.exe or winedevice.exe is left" \
  '[ -z "$(find "$WINE" \( -iname wineboot.exe -o -iname winedevice.exe \))" ]'
check "wine.inf installs ano-boot.exe and ano-device.exe" \
  'grep -q "^11,,ano-boot.exe,-" "$WINE/share/wine/wine.inf" && grep -q "^11,,ano-device.exe" "$WINE/share/wine/wine.inf"'
# Any file that still names the old programs, as text or as Windows wide text.
leftovers="$(python3 - "$WINE" <<'EOF'
import os, sys
needles = [n.encode(e) for n in ("wineboot.exe", "winedevice.exe") for e in ("ascii", "utf-16-le")]
for dirpath, _, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        data = open(path, "rb").read().lower()
        if any(n in data for n in needles):
            print(os.path.relpath(path, sys.argv[1]))
EOF
)"
check "no file names wineboot.exe or winedevice.exe" '[ -z "$leftovers" ]'
[ -n "$leftovers" ] && echo "$leftovers" | sed 's/^/     still named in: /'

# Runs a command in a bottle while recording the Windows programs it starts.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-programs-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
in_bottle() { # <bin-dir> <prefix> <ps-log> <command...>
  local bin="$1" prefix="$2" log="$3"; shift 3
  WINEPREFIX="$prefix" WINESERVER="$bin/ano-server" WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" "$bin/ano-loader" "$@" > "$WORK/out.txt" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do ps -axo command= >> "$log"; sleep 0.3; done
  wait "$pid"; local status=$?
  WINEPREFIX="$prefix" "$bin/ano-server" -w
  return "$status"
}
saw() { grep -qiE "$1" "$2"; }

if [ "$BOOT" -eq 1 ]; then
  echo "== new bottle"
  P="$WORK/new"; L="$WORK/new.ps"; : > "$L"
  in_bottle "$BIN" "$P" "$L" cmd /c echo ready; status=$?
  check "bottle created" '[ "$status" -eq 0 ] && [ -f "$P/system.reg" ]'
  check "ano-boot.exe ran" 'saw "system32.ano-boot.exe" "$L"'
  check "ano-device.exe ran" 'saw "system32.ano-device.exe" "$L"'
  check "wineboot.exe and winedevice.exe never ran" '! saw "wineboot\.exe|winedevice\.exe" "$L"'
  check "bottle has ano-boot.exe and ano-device.exe" \
    '[ -f "$P/drive_c/windows/system32/ano-boot.exe" ] && [ -f "$P/drive_c/windows/system32/ano-device.exe" ] && [ -f "$P/drive_c/windows/syswow64/ano-device.exe" ]'
  check "bottle has no wineboot.exe or winedevice.exe" \
    '[ -z "$(find "$P/drive_c/windows" -maxdepth 2 \( -iname wineboot.exe -o -iname winedevice.exe \))" ]'
  L2="$WORK/sc.ps"; : > "$L2"
  in_bottle "$BIN" "$P" "$L2" sc query MountMgr
  check "a driver runs in ano-device.exe (MountMgr RUNNING)" 'grep -q "RUNNING" "$WORK/out.txt"'
  grep -i "STATE" "$WORK/out.txt" | sed 's/^/     /'
fi

if [ -n "$EXITWIN" ]; then
  echo "== shutdown through user32"
  P="$WORK/new"; L="$WORK/exit.ps"; : > "$L"
  in_bottle "$BIN" "$P" "$L" "$EXITWIN"
  check "ExitWindowsEx started ano-boot.exe" 'grep -q "ExitWindowsEx=1" "$WORK/out.txt" && saw "ano-boot.exe.*--end-session" "$L"'
  sed 's/^/     /' "$WORK/out.txt" | head -5
fi

if [ -n "$OLD" ]; then
  echo "== bottle made by an older runtime"
  P="$WORK/old"; L="$WORK/old.ps"; : > "$L"
  in_bottle "$OLD/Wine/bin" "$P" "$L" cmd /c echo old
  check "older runtime made the bottle" '[ -f "$P/system.reg" ]'
  : > "$L"
  in_bottle "$BIN" "$P" "$L" cmd /c echo upgraded; status=$?
  check "opens with this runtime" '[ "$status" -eq 0 ] && grep -q upgraded "$WORK/out.txt"'
  check "update ran ano-boot.exe" 'saw "system32.ano-boot.exe" "$L"'
  check "update installed ano-boot.exe and ano-device.exe" \
    '[ -f "$P/drive_c/windows/system32/ano-boot.exe" ] && [ -f "$P/drive_c/windows/system32/ano-device.exe" ]'
  : > "$L"
  in_bottle "$BIN" "$P" "$L" sc query MountMgr
  check "drivers still run after the update" 'grep -q "RUNNING" "$WORK/out.txt"'
fi

if [ -n "$WINETRICKS" ]; then
  echo "== winetricks"
  check "winetricks creates bottles with ano-boot" \
    'grep -q "\"\${WINE}\" ano-boot" "$WINETRICKS" && ! grep -q "\"\${WINE}\" wineboot" "$WINETRICKS"'
  P="$WORK/tricks"
  WINE="$BIN/ano-loader" WINESERVER="$BIN/ano-server" WINEPREFIX="$P" WINEARCH=win64 WINEDEBUG=-all \
    bash "$WINETRICKS" -q list-installed > "$WORK/tricks.txt" 2>&1; status=$?
  check "winetricks list-installed works on a new bottle" '[ "$status" -eq 0 ] && [ -f "$P/system.reg" ]'
  [ "$status" -eq 0 ] || tail -5 "$WORK/tricks.txt" | sed 's/^/     /'
fi

exit "$fail"
