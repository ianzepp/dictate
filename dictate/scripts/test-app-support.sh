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
    if [ "$check_name" = Recorder ] || [ "$check_name" = VolumeDucker ]; then
        if [ ! -f "$CHECK_DIR/libDictateCore.dylib" ]; then
            swiftc -emit-library -emit-module -module-name DictateCore "$ROOT"/Sources/DictateCore/*.swift \
                -emit-module-path "$CHECK_DIR/DictateCore.swiftmodule" -o "$CHECK_DIR/libDictateCore.dylib"
        fi
        swiftc -parse-as-library "$CHECK_DIR/Check.swift" -I "$CHECK_DIR" -L "$CHECK_DIR" -lDictateCore \
            -Xlinker -rpath -Xlinker "$CHECK_DIR" -o "$CHECK_DIR/check"
    else
        swiftc -parse-as-library "$CHECK_DIR/Check.swift" -o "$CHECK_DIR/check"
    fi
    "$CHECK_DIR/check"
}

case "${1:-all}" in
    all) check_helper DebugTrail DebugTrail.swift; check_helper Pasteboard Paste.swift; check_helper Recorder Recorder.swift; check_helper VolumeDucker VolumeDucker.swift ;;
    DebugTrail) check_helper DebugTrail DebugTrail.swift ;;
    Pasteboard) check_helper Pasteboard Paste.swift ;;
    Recorder) check_helper Recorder Recorder.swift ;;
    VolumeDucker) check_helper VolumeDucker VolumeDucker.swift ;;
    *) echo "Usage: $0 [all|DebugTrail|Pasteboard|Recorder|VolumeDucker]" >&2; exit 2 ;;
esac
