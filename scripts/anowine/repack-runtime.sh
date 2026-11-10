#!/bin/bash
# Builds AnoWine's Wine runtime: upstream's published Libraries.tar.gz with the
# two Wine programs renamed (wine64/wine -> ano-loader, wineserver -> ano-server)
# and three Windows-side names changed: the Wine loader lib/wine/x86_64-unix/wine
# is ano-core, wineboot.exe is ano-boot.exe and winedevice.exe is ano-device.exe.
# The modules that start those by name are replaced with ones built by
# build-modules.sh with scripts/anowine/patches/*.patch.
# Recipe and evidence: spikes/REPORT.md section 2.
#
# Usage: scripts/anowine/repack-runtime.sh <out-dir> <build-modules out-dir>
# Produces <out-dir>/Libraries.tar.gz and prints its SHA-256. macOS only
# (PlistBuddy, BSD tar). Fails closed on any unexpected layout.
set -euo pipefail

OUT="$(mkdir -p "${1:?usage: repack-runtime.sh <out-dir> <modules-dir>}" && cd "$1" && pwd)"
MODULES="$(cd "${2:?usage: repack-runtime.sh <out-dir> <modules-dir>}/Wine" && pwd)"
grep -aq "%s%s/ano-core" "$MODULES/lib/wine/x86_64-unix/ntdll.so" || { echo "error: built ntdll.so does not start ano-core" >&2; exit 1; }

# ---- pinned inputs ----------------------------------------------------------
BASE_URL="https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz"
BASE_SHA256="01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3"
VERSION_MAJOR=3 VERSION_MINOR=1 VERSION_PATCH=5
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
[ -L "$BIN/wine64" ] && [ "$(readlink "$BIN/wine64")" = "wine" ] || { echo "error: expected wine64 -> wine symlink" >&2; exit 1; }
[ -f "$BIN/wine" ] && [ ! -L "$BIN/wine" ] || { echo "error: expected real file Wine/bin/wine" >&2; exit 1; }
[ -f "$BIN/wineserver" ] && [ ! -L "$BIN/wineserver" ] || { echo "error: expected real file Wine/bin/wineserver" >&2; exit 1; }
# Every tool link (wine64, winecfg, regedit, ...) points at `wine` and would
# dangle after the rename; the app runs tools as `ano-loader <tool>`, so drop them.
find "$BIN" -type l -exec sh -c '[ "$(readlink "$1")" = wine ] && rm "$1" && echo "removed link $(basename "$1")"' _ {} \;
mv "$BIN/wine" "$BIN/$LOADER"
mv "$BIN/wineserver" "$BIN/$SERVER"

echo "== rename the Wine loader to $CORE"
UNIX="$LIB/Wine/lib/wine/x86_64-unix"
[ -f "$UNIX/wine" ] && [ ! -L "$UNIX/wine" ] || { echo "error: expected real file lib/wine/x86_64-unix/wine" >&2; exit 1; }
mv "$UNIX/wine" "$UNIX/$CORE"

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

echo "== verify layout"
fail=0
for f in "$LOADER" "$SERVER"; do
  [ -x "$BIN/$f" ] || { echo "error: Wine/bin/$f missing or not executable" >&2; fail=1; }
done
for f in wine wine64 wineserver; do
  [ ! -e "$BIN/$f" ] && [ ! -L "$BIN/$f" ] || { echo "error: Wine/bin/$f still present" >&2; fail=1; }
done
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
