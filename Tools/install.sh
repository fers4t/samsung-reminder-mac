#!/bin/sh
# Builds the app (Release by default) and installs it into /Applications.
# Usage: Tools/install.sh [Debug|Release]
set -eu
CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -d SamsungReminder.xcodeproj ] || xcodegen generate
xcodebuild -project SamsungReminder.xcodeproj -scheme SamsungReminder -configuration "$CONFIG" build | grep -E "error:|BUILD" || true
APP="$(xcodebuild -project SamsungReminder.xcodeproj -scheme SamsungReminder -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Samsung Reminder.app"
[ -d "$APP" ] || { echo "build product not found: $APP" >&2; exit 1; }
pkill -x "Samsung Reminder" 2>/dev/null || true
rm -rf "/Applications/Samsung Reminder.app"
ditto "$APP" "/Applications/Samsung Reminder.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Samsung Reminder.app" >/dev/null 2>&1 || true
echo "installed /Applications/Samsung Reminder.app ($CONFIG)"
