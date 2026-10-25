#!/bin/bash
# Fails unless the published AnoWine runtime asset's SHA-256 equals the sha256
# (and version) advertised in dist/pages/WhiskyWineVersion.plist. A wrong
# digest there blocks every first-run install, so CI checks it.
#
# Usage: scripts/anowine/check-runtime-digest.sh [repo-root]
set -euo pipefail
ROOT="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"
PLIST="$ROOT/dist/pages/WhiskyWineVersion.plist"
REPO="${GITHUB_REPOSITORY:-HighStormPVP/AnoWine}"

read -r VERSION WANT < <(python3 - "$PLIST" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
v = d["version"]
print("%d.%d.%d" % (v["major"], v["minor"], v["patch"]), d.get("sha256", "-"))
EOF
)
URL="https://github.com/$REPO/releases/download/v$VERSION/Libraries.tar.gz"
echo "plist advertises v$VERSION sha256 $WANT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/Libraries.tar.gz" "$URL" || { echo "::error::cannot download $URL"; exit 1; }
GOT="$( (sha256sum "$TMP/Libraries.tar.gz" 2>/dev/null || shasum -a 256 "$TMP/Libraries.tar.gz") | awk '{print $1}')"
echo "published asset sha256 $GOT"
if [ "$GOT" != "$WANT" ]; then
  echo "::error::dist/pages/WhiskyWineVersion.plist sha256 does not match the v$VERSION release asset"
  exit 1
fi
echo "digest OK"
