#!/bin/bash
# Validate the native candidate, migrate the obsolete port setting, then swap
# the app and install its single login job. Existing app/config are backed up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dictate/dist/Dictate.app"
NEXT="$ROOT/dictate/dist/Dictate.next.app"
CONFIG="$HOME/.config/dictate/config.toml"

fail() { echo "install.sh: $*" >&2; exit 1; }
[ -x "$NEXT/Contents/MacOS/Dictate" ] || fail "run dictate/scripts/build-app.sh first"
[ -f "$CONFIG" ] || fail "no config; copy config.example.toml to $CONFIG"
CANDIDATE="$(mktemp "$(dirname "$CONFIG")/.config-native.XXXXXX")"
trap 'if [ -f "$CANDIDATE" ]; then /bin/rm "$CANDIDATE"; fi' EXIT
# One-time data migration. The native reader rejects this dead service option.
awk '
  /^[ \t]*\[/ { speech = ($0 ~ /^[ \t]*\[[ \t]*(speech|"speech"|\047speech\047)[ \t]*\][ \t]*(#.*)?$/) }
  speech && /^[ \t]*(port|"port"|\047port\047)[ \t]*=/ { next }
  { print }
' "$CONFIG" > "$CANDIDATE"
"$NEXT/Contents/MacOS/Dictate" --check-config "$CANDIDATE" || fail "fix the config above, then run this again"

UID_NUM="$(id -u)"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Logs/Dictate" "$DEST"

stop() {
    launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1 || return 0
    launchctl bootout "gui/$UID_NUM/$1" || fail "could not stop $1"
    # bootout returns before the job is gone; bootstrap fails with error 5 until it is.
    for _ in $(seq 50); do
        launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1 || break
        sleep 0.1
    done
    if launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1; then fail "$1 did not stop"; fi
}

BACKUP="$(mktemp -d "$ROOT/dictate/dist/.native-backup.XXXXXX")"
cp -p "$CONFIG" "$BACKUP/config.toml"
if [ -f "$DEST/com.ianzepp.dictate.speech.plist" ]; then
    cp -p "$DEST/com.ianzepp.dictate.speech.plist" "$BACKUP/speech.plist"
fi
stop com.ianzepp.dictate
stop com.ianzepp.dictate.speech
if [ -d "$APP" ]; then mv "$APP" "$BACKUP/Dictate.app"; fi
mv "$NEXT" "$APP"
if ! cmp -s "$CONFIG" "$CANDIDATE"; then
    chmod "$(/usr/bin/stat -f %Lp "$CONFIG")" "$CANDIDATE"
    mv "$CANDIDATE" "$CONFIG"
fi
LABEL=com.ianzepp.dictate
JOB="$(mktemp "$DEST/.dictate-native.XXXXXX")"
sed -e "s|__ROOT__|$ROOT|g" -e "s|__HOME__|$HOME|g" \
    "$ROOT/launchd/$LABEL.plist" > "$JOB"
plutil -lint -s "$JOB"
chmod 644 "$JOB"
mv "$JOB" "$DEST/$LABEL.plist"
launchctl bootstrap "gui/$UID_NUM" "$DEST/$LABEL.plist"
if [ -f "$DEST/com.ianzepp.dictate.speech.plist" ]; then
    /bin/rm "$DEST/com.ianzepp.dictate.speech.plist"
fi
echo "started native Dictate; previous app/config saved in $BACKUP"
