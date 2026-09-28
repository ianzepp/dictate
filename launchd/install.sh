#!/bin/bash
# Copy the two LaunchAgents into place and bootstrap them for this login session.
# Run this only after the turbo weights exist and dictate/scripts/build-app.sh has built the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UID_NUM="$(id -u)"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$HOME/ai/logs" "$DEST"
for label in com.ianzepp.stt.2pass com.ianzepp.stt com.ianzepp.stt.dictate; do
    cp "$ROOT/launchd/$label.plist" "$DEST/$label.plist"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_NUM" "$DEST/$label.plist"
    echo "bootstrapped $label"
done
