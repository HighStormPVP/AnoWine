#!/bin/bash
# Runs the CLI bundled in a built AnoWine.app on a fresh machine and asserts it
# uses AnoWine's data folder, never Whisky's. WhiskyCmd has no Info.plist of
# its own, so this is the only check that sees which identity it resolves.
#
# Usage: check-cli-identity.sh <path/to/AnoWine.app>   (CI runners only: it
# fails if Whisky data already exists on the machine)
set -uo pipefail
APP="$(cd "${1:?usage: check-cli-identity.sh <path/to/AnoWine.app>}" && pwd)"
CLI="$APP/Contents/Resources/WhiskyCmd"
CONTAINERS="$HOME/Library/Containers"
SUPPORT="$HOME/Library/Application Support"
status=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "::error::$1"; status=1; fi; }

check "bundled CLI exists" '[ -x "$CLI" ]'
check "no Whisky data before the run" '! ls -d "$CONTAINERS"/com.franke.* "$SUPPORT"/com.franke.* >/dev/null 2>&1'
"$CLI" list || { echo "::error::WhiskyCmd list failed"; status=1; }
check "CLI created AnoWine's bottle registry" '[ -f "$CONTAINERS/io.github.highstormpvp.AnoWine/BottleVM.plist" ]'
check "CLI touched no Whisky folder" '! ls -d "$CONTAINERS"/com.franke.* "$SUPPORT"/com.franke.* >/dev/null 2>&1'
exit "$status"
