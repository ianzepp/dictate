#!/bin/bash
# Compile app helpers with their checks, without starting the menu-bar app.
# Keeping each check in the same compilation file permits private-member checks
# without changing production visibility or accessing the real microphone/logs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d /private/tmp/dictate-app-checks.XXXXXX)"
trap '/bin/rm -r "$CHECK_DIR"' EXIT

check_helper() {
    local check_name="$1" primary_source="$2"
    cat "$ROOT/Sources/Dictate/$primary_source" "$ROOT/Tests/AppChecks/${check_name}Checks.swift" > "$CHECK_DIR/Check.swift"
    swiftc -parse-as-library "$CHECK_DIR/Check.swift" -o "$CHECK_DIR/check"
    "$CHECK_DIR/check"
}

case "${1:-all}" in
    all) check_helper DebugTrail DebugTrail.swift; check_helper Pasteboard Paste.swift ;;
    DebugTrail) check_helper DebugTrail DebugTrail.swift ;;
    Pasteboard) check_helper Pasteboard Paste.swift ;;
    *) echo "Usage: $0 [all|DebugTrail|Pasteboard]" >&2; exit 2 ;;
esac
