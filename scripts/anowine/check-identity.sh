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

check "app bundle is named Ano.app" '[ "$(basename "$APP")" = "Ano.app" ]'
check "CFBundleIdentifier is io.github.highstormpvp.Ano" \
  '[ "$("$PB" -c "Print :CFBundleIdentifier" "$PLIST")" = "io.github.highstormpvp.Ano" ]'
check "URL scheme is ano" \
  '[ "$("$PB" -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$PLIST")" = "ano" ]'
check "no frankea / com.franke strings in Info.plist" '! grep -q "frankea\|com\.franke" "$PLIST"'
check "no AnoWine or Whisky in the app's visible name or permission prompts" \
  '! /usr/libexec/PlistBuddy -c "Print" "$PLIST" | grep -E "CFBundleName|UsageDescription" | grep -qE "AnoWine|Whisky"'
check "no Sparkle public key (frankea updates must not verify)" '! "$PB" -c "Print :SUPublicEDKey" "$PLIST" >/dev/null 2>&1'
check "Sparkle automatic checks off" '[ "$("$PB" -c "Print :SUEnableAutomaticChecks" "$PLIST")" = "false" ]'
check "no PostHog project token" '! "$PB" -c "Print :PostHogProjectToken" "$PLIST" >/dev/null 2>&1'
exit "$status"
