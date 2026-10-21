#!/bin/bash
# Fill in the LaunchAgent templates for this Mac, copy them into place, and start them.
# Run this after dictate/scripts/build-app.sh has built the app.
#
# Set PYTHON for a Python with requirements.txt installed (default: <repo>/.venv/bin/python).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"
APP="$ROOT/dictate/dist/Dictate.app"
CONFIG="$HOME/.config/dictate/config.toml"

fail() { echo "install.sh: $*" >&2; exit 1; }
[ -x "$PYTHON" ] || fail "no Python at $PYTHON; create the venv or set PYTHON"
[ -d "$APP" ] || fail "no app at $APP; run dictate/scripts/build-app.sh first"
[ -f "$CONFIG" ] || fail "no config; copy config.example.toml to $CONFIG"
DICTATE_CONFIG="$CONFIG" "$PYTHON" "$ROOT/stt_server.py" --check || fail "fix the config above, then run this again"

UID_NUM="$(id -u)"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Logs/Dictate" "$DEST"

stop() {
    launchctl bootout "gui/$UID_NUM/$1" 2>/dev/null || true
    # bootout returns before the job is gone; bootstrap fails with error 5 until it is.
    for _ in $(seq 50); do
        launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1 || break
        sleep 0.2
    done
}

for label in com.ianzepp.dictate.speech com.ianzepp.dictate; do
    sed -e "s|__ROOT__|$ROOT|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__PYTHON__|$PYTHON|g" \
        "$ROOT/launchd/$label.plist" > "$DEST/$label.plist"
    plutil -lint -s "$DEST/$label.plist"
    stop "$label"
    launchctl bootstrap "gui/$UID_NUM" "$DEST/$label.plist"
    echo "started $label"
done
