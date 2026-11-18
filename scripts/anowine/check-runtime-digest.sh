#!/bin/bash
# Fails unless every runtime feed, dist/pages/WhiskyWineVersion*.plist, names a
# published AnoWine runtime by its exact digest: the release v<version> asset
# Libraries.tar.gz must have the sha256 the feed advertises. A wrong digest in
# a feed blocks every first-run install of the apps that read it, so CI checks
# them all. WhiskyWineVersion.plist is the frozen feed Ano 6 and 7 read;
# WhiskyWineVersion-v4.plist is the one Ano 8 and later read.
#
# Prints "digest OK <file> v<version>" for each feed that matches.
# Usage: scripts/anowine/check-runtime-digest.sh [repo-root]
set -uo pipefail
ROOT="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"
REPO="${GITHUB_REPOSITORY:-HighStormPVP/AnoWine}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
feeds=("$ROOT"/dist/pages/WhiskyWineVersion*.plist)
[ -e "${feeds[0]}" ] || { echo "::error::no runtime feeds in $ROOT/dist/pages"; exit 1; }
for PLIST in "${feeds[@]}"; do
  NAME="$(basename "$PLIST")"
  if ! read -r VERSION WANT < <(python3 - "$PLIST" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
v = d["version"]
print("%d.%d.%d" % (v["major"], v["minor"], v["patch"]), d.get("sha256", "-"))
EOF
  ); then
    echo "::error::$NAME cannot be read"; fail=1; continue
  fi
  URL="https://github.com/$REPO/releases/download/v$VERSION/Libraries.tar.gz"
  echo "$NAME advertises v$VERSION sha256 $WANT"
  rm -f "$TMP/Libraries.tar.gz"
  if ! curl -fsSL -o "$TMP/Libraries.tar.gz" "$URL"; then
    echo "::error::$NAME: cannot download $URL"; fail=1; continue
  fi
  GOT="$( (sha256sum "$TMP/Libraries.tar.gz" 2>/dev/null || shasum -a 256 "$TMP/Libraries.tar.gz") | awk '{print $1}')"
  echo "published asset sha256 $GOT"
  if [ "$GOT" != "$WANT" ]; then
    echo "::error::$NAME sha256 does not match the v$VERSION release asset"; fail=1; continue
  fi
  echo "digest OK $NAME v$VERSION"
done
exit "$fail"
