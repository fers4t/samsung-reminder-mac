#!/bin/sh
# Builds a redistributable, ad-hoc signed Release zip with the public identifiers
# (com.example, no team), so no developer identity leaks into the artifact.
# Usage: Tools/release.sh  -> build/Samsung-Reminder-<version>.zip
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -d SamsungReminder.xcodeproj ] || xcodegen generate
OUT="$ROOT/build/release"
rm -rf "$OUT"
LOG="$(mktemp)"
GROUP="group.com.example.SamsungReminder"
# Xcode refuses to sign an App Group entitlement without a provisioning profile, so build unsigned
# (as CI does) and ad-hoc sign afterwards with the same entitlements, group id resolved.
xcodebuild -project SamsungReminder.xcodeproj -scheme SamsungReminder -configuration Release build \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO \
  BUNDLE_ID_PREFIX=com.example DEVELOPMENT_TEAM= APP_GROUP_ID="$GROUP" >"$LOG" 2>&1 \
  || { grep -E "error:|BUILD" "$LOG" >&2; rm -f "$LOG"; exit 1; }
rm -f "$LOG"
APP="$OUT/DerivedData/Build/Products/Release/Samsung Reminder.app"
sign() { # $1 = entitlements template, $2 = bundle
  sed "s/\$(APP_GROUP_ID)/$GROUP/" "$1" >"$OUT/ent.plist"
  codesign --force --sign - --options runtime --timestamp=none --entitlements "$OUT/ent.plist" "$2"
}
sign Sources/Widget/SamsungReminderWidget.entitlements "$APP/Contents/PlugIns/SamsungReminderWidget.appex"
sign Sources/App/SamsungReminder.entitlements "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
codesign --verify --deep --strict "$APP"
# The artifact must not reveal the local signing identity.
if codesign -dvv "$APP" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]"; then echo "team id leaked into signature" >&2; exit 1; fi
ZIP="$ROOT/build/Samsung-Reminder-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
