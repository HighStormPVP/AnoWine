#!/bin/bash
# Builds AnoWine's Wine runtime: upstream's published Libraries.tar.gz with the
# two Wine programs renamed (wine64/wine -> ano-loader, wineserver -> ano-server)
# and the Wine loader lib/wine/x86_64-unix/wine renamed ano-core. ntdll.so starts
# that loader by name, so it is replaced with one built by build-ntdll.sh with
# patches/ntdll-ano-core.patch. Recipe and evidence: spikes/REPORT.md section 2.
#
# Usage: scripts/anowine/repack-runtime.sh <out-dir> <ano-core ntdll.so>
# Produces <out-dir>/Libraries.tar.gz and prints its SHA-256. macOS only
# (PlistBuddy, BSD tar). Fails closed on any unexpected layout.
set -euo pipefail

OUT="$(mkdir -p "${1:?usage: repack-runtime.sh <out-dir> <ntdll.so>}" && cd "$1" && pwd)"
NTDLL="$(cd "$(dirname "${2:?usage: repack-runtime.sh <out-dir> <ntdll.so>}")" && pwd)/$(basename "$2")"
grep -aq "%s%s/ano-core" "$NTDLL" || { echo "error: $NTDLL does not start ano-core" >&2; exit 1; }

# ---- pinned inputs ----------------------------------------------------------
BASE_URL="https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz"
BASE_SHA256="01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3"
VERSION_MAJOR=3 VERSION_MINOR=1 VERSION_PATCH=4
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

echo "== rename the Wine loader to $CORE and install its ntdll.so"
UNIX="$LIB/Wine/lib/wine/x86_64-unix"
[ -f "$UNIX/wine" ] && [ ! -L "$UNIX/wine" ] || { echo "error: expected real file lib/wine/x86_64-unix/wine" >&2; exit 1; }
mv "$UNIX/wine" "$UNIX/$CORE"
cp "$NTDLL" "$UNIX/ntdll.so"
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
ls -la "$BIN"

echo "== repack"
rm -f "$OUT/Libraries.tar.gz"
( cd "$WORK" && COPYFILE_DISABLE=1 tar --no-xattrs -czf "$OUT/Libraries.tar.gz" Libraries )
echo "SHA-256: $(shasum -a 256 "$OUT/Libraries.tar.gz" | awk '{print $1}')"
