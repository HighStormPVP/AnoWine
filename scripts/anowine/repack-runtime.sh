#!/bin/bash
# Builds Ano's Wine runtime: upstream's published engine (frankea/Whisky v4.8.3,
# Wine 11.19 with CrossOver's macOS patches) with Ano's names. The Wine loader
# lib/wine/x86_64-unix/wine is ano-core and bin/ano-loader links to it (in place
# of bin/wine, wine64 and wineloader), wineserver is ano-server, wineboot.exe is
# ano-boot.exe and winedevice.exe is ano-device.exe. The modules that start
# those by name are replaced with ones build-modules.sh builds from the engine's
# own source with scripts/anowine/patches/*.patch.
# Recipe and evidence: spikes/REPORT.md section 2; Plan 3a.
#
# Usage: scripts/anowine/repack-runtime.sh <out-dir> <build-modules out-dir>
# Produces <out-dir>/Libraries.tar.gz and prints its SHA-256. macOS only
# (PlistBuddy, BSD tar). Fails closed on any unexpected layout.
set -euo pipefail

OUT="$(mkdir -p "${1:?usage: repack-runtime.sh <out-dir> <modules-dir>}" && cd "$1" && pwd)"
MODULES="$(cd "${2:?usage: repack-runtime.sh <out-dir> <modules-dir>}/Wine" && pwd)"
grep -aq "%s%s/ano-core" "$MODULES/lib/wine/x86_64-unix/ntdll.so" || { echo "error: built ntdll.so does not start ano-core" >&2; exit 1; }

# ---- pinned inputs ----------------------------------------------------------
BASE_URL="https://github.com/frankea/Whisky/releases/download/v4.8.3/Libraries.tar.gz"
BASE_SHA256="08ffabd7b7c352470faee2b1d51061b341316e401439ca805c5302acc2fb8818"
VERSION_MAJOR=4 VERSION_MINOR=9 VERSION_PATCH=0
LOADER=ano-loader
SERVER=ano-server
CORE=ano-core
# -----------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anowine-runtime-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "== fetch and verify upstream runtime"
curl -fsSL -o "$WORK/base.tar.gz" "$BASE_URL"
echo "$BASE_SHA256  $WORK/base.tar.gz" | shasum -a 256 -c - || { echo "error: base runtime digest mismatch" >&2; exit 1; }
tar -xzf "$WORK/base.tar.gz" -C "$WORK"
rm -f "$WORK/base.tar.gz"
LIB="$WORK/Libraries"
BIN="$LIB/Wine/bin"

echo "== rename programs"
# The engine's bin holds links to the loader under three names, and the server.
for n in wine wine64 wineloader; do
  [ -L "$BIN/$n" ] && [ "$(readlink "$BIN/$n")" = ../lib/wine/x86_64-unix/wine ] ||
    { echo "error: expected Wine/bin/$n -> ../lib/wine/x86_64-unix/wine" >&2; exit 1; }
  rm "$BIN/$n"
done
[ -f "$BIN/wineserver" ] && [ ! -L "$BIN/wineserver" ] || { echo "error: expected real file Wine/bin/wineserver" >&2; exit 1; }
mv "$BIN/wineserver" "$BIN/$SERVER"

echo "== rename the Wine loader to $CORE"
UNIX="$LIB/Wine/lib/wine/x86_64-unix"
[ -f "$UNIX/wine" ] && [ ! -L "$UNIX/wine" ] || { echo "error: expected real file lib/wine/x86_64-unix/wine" >&2; exit 1; }
mv "$UNIX/wine" "$UNIX/$CORE"
# Wine's loader looks for ntdll.so beside its resolved path, so bin gets a link, not a copy.
ln -s "../lib/wine/x86_64-unix/$CORE" "$BIN/$LOADER"

echo "== replace wineboot.exe and winedevice.exe with ano-boot.exe and ano-device.exe"
WINDOWS="$LIB/Wine/lib/wine"
for f in x86_64-windows/wineboot.exe x86_64-windows/winedevice.exe i386-windows/winedevice.exe; do
  [ -f "$WINDOWS/$f" ] || { echo "error: expected lib/wine/$f" >&2; exit 1; }
  rm "$WINDOWS/$f"
done
# The built wine.inf must be upstream's with only the two install lines changed.
changed="$(diff "$LIB/Wine/share/wine/wine.inf" "$MODULES/share/wine/wine.inf" | grep -c '^[<>]' || true)"
[ "$changed" = 4 ] || { echo "error: built wine.inf differs from upstream in $changed lines, expected 4" >&2;
  diff "$LIB/Wine/share/wine/wine.inf" "$MODULES/share/wine/wine.inf" | head -20 >&2; exit 1; }
# Every replacement must take the place of a file upstream ships, or be a renamed program.
( cd "$MODULES" && find . -type f ) | while read -r f; do
  case "$f" in */ano-boot.exe|*/ano-device.exe) ;; *)
    [ -f "$LIB/Wine/$f" ] || { echo "error: built $f replaces nothing upstream ships" >&2; exit 1; } ;;
  esac
  install -m 644 "$MODULES/$f" "$LIB/Wine/$f"
done
chmod 755 "$UNIX/ntdll.so"

echo "== set runtime version $VERSION_MAJOR.$VERSION_MINOR.$VERSION_PATCH"
PLIST="$LIB/WhiskyWineVersion.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :version:major $VERSION_MAJOR" -c "Set :version:minor $VERSION_MINOR" -c "Set :version:patch $VERSION_PATCH" "$PLIST"
"$PB" -c "Delete :sha256" "$PLIST" 2>/dev/null || true
plutil -lint "$PLIST"
# The app deploys an imported Game Porting Toolkit only into a gptkCapable runtime.
for kv in gptkCapable=true dxvkVersion=1.10.3 dxmtVersion=0.80; do
  [ "$("$PB" -c "Print :${kv%%=*}" "$PLIST" 2>/dev/null)" = "${kv#*=}" ] ||
    { echo "error: $PLIST: ${kv%%=*} is not ${kv#*=}" >&2; exit 1; }
done

echo "== verify layout"
fail=0
for f in "$LOADER" "$SERVER"; do
  [ -x "$BIN/$f" ] || { echo "error: Wine/bin/$f missing or not executable" >&2; fail=1; }
done
[ "$(ls -A "$BIN" | sort | tr '\n' ' ')" = "$LOADER $SERVER " ] ||
  { echo "error: Wine/bin holds more than $LOADER and $SERVER:" >&2; ls -A "$BIN" >&2; fail=1; }
dangling="$(find "$LIB" -type l ! -exec test -e {} \; -print)"
[ -z "$dangling" ] || { echo "error: dangling symlinks:" >&2; echo "$dangling" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1
bash "$(dirname "$0")/check-ano-core.sh" "$LIB"
bash "$(dirname "$0")/check-ano-programs.sh" "$LIB"
ls -la "$BIN"

echo "== repack"
rm -f "$OUT/Libraries.tar.gz"
( cd "$WORK" && COPYFILE_DISABLE=1 tar --no-xattrs -czf "$OUT/Libraries.tar.gz" Libraries )
echo "SHA-256: $(shasum -a 256 "$OUT/Libraries.tar.gz" | awk '{print $1}')"
