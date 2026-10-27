#!/bin/bash
# Compile app helpers with their checks, without starting the menu-bar app.
# Keeping each check in the same compilation file permits private-member checks
# without changing production visibility or accessing the real microphone/logs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d /private/tmp/dictate-app-checks.XXXXXX)"
trap '/bin/rm -r "$TEMP"' EXIT

check_debug_trail() {
    cat "$ROOT/Sources/Dictate/DebugTrail.swift" "$ROOT/Tests/AppChecks/DebugTrailChecks.swift" > "$TEMP/Check.swift"
    swiftc -parse-as-library "$TEMP/Check.swift" -o "$TEMP/check"
    "$TEMP/check"
}

case "${1:-all}" in
    all|DebugTrail) check_debug_trail ;;
    *) echo "Usage: $0 [all|DebugTrail]" >&2; exit 2 ;;
esac
