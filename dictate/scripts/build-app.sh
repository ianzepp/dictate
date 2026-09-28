#!/bin/bash
# Build the menu-bar app bundle. Does not install or launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/Dictate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Dictate "$APP/Contents/MacOS/Dictate"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signatures get a new identity every build, so macOS drops the
# Accessibility grant. A stable local certificate keeps the approval.
SIGN_ID="Dictate Local Code Sign"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --identifier com.ianzepp.stt.dictate "$APP"
else
  echo "warning: $SIGN_ID is missing; Accessibility will not stick" >&2
  codesign --force --sign - "$APP"
fi
echo "built $(pwd)/$APP"
