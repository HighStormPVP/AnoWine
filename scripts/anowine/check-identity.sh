#!/bin/bash
# Asserts a built AnoWine.app does not carry Whisky's identity, update feed,
# update signing key or analytics project. Usage: check-identity.sh <path/to/AnoWine.app>
set -uo pipefail
APP="${1:?usage: check-identity.sh <path/to/AnoWine.app>}"
APP="$(cd "$APP" && pwd)"
PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
status=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "::error::$1"; status=1; fi; }

check "app bundle is named AnoWine.app" '[ "$(basename "$APP")" = "AnoWine.app" ]'
check "CFBundleIdentifier is io.github.highstormpvp.AnoWine" \
  '[ "$("$PB" -c "Print :CFBundleIdentifier" "$PLIST")" = "io.github.highstormpvp.AnoWine" ]'
check "URL scheme is anowine" \
  '[ "$("$PB" -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$PLIST")" = "anowine" ]'
check "no frankea / com.franke strings in Info.plist" '! grep -q "frankea\|com\.franke" "$PLIST"'
check "no Sparkle public key (frankea updates must not verify)" '! "$PB" -c "Print :SUPublicEDKey" "$PLIST" >/dev/null 2>&1'
check "Sparkle automatic checks off" '[ "$("$PB" -c "Print :SUEnableAutomaticChecks" "$PLIST")" = "false" ]'
check "no PostHog project token" '! "$PB" -c "Print :PostHogProjectToken" "$PLIST" >/dev/null 2>&1'
exit "$status"
