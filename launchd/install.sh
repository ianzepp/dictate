#!/bin/bash
# Fill in the LaunchAgent templates for this Mac, copy them into place, and start them.
# Run this after the models are downloaded and dictate/scripts/build-app.sh has built the app.
#
# Override any of these in the environment:
#   PYTHON        Python with requirements.txt installed  (default: <repo>/.venv/bin/python)
#   LLAMA_SERVER  llama.cpp server binary                  (default: llama-server on PATH)
#   LLM_MODEL     GGUF file for the cleanup model          (default: ~/.local/share/dictate/models/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"
LLAMA_SERVER="${LLAMA_SERVER:-$(command -v llama-server || true)}"
LLM_MODEL="${LLM_MODEL:-$HOME/.local/share/dictate/models/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf}"
APP="$ROOT/dictate/dist/Dictate.app"

fail() { echo "install.sh: $*" >&2; exit 1; }
[ -x "$PYTHON" ] || fail "no Python at $PYTHON; create the venv or set PYTHON"
[ -n "$LLAMA_SERVER" ] && [ -x "$LLAMA_SERVER" ] || fail "llama-server not found; brew install llama.cpp or set LLAMA_SERVER"
[ -f "$LLM_MODEL" ] || fail "no cleanup model at $LLM_MODEL; download it or set LLM_MODEL"
[ -d "$APP" ] || fail "no app at $APP; run dictate/scripts/build-app.sh first"
[ -f "$HOME/.config/stt-service/config.toml" ] || fail "no config; copy config.example.toml to ~/.config/stt-service/config.toml"

UID_NUM="$(id -u)"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Logs/Dictate" "$DEST"
for label in com.ianzepp.stt.2pass com.ianzepp.stt com.ianzepp.stt.dictate; do
    sed -e "s|__ROOT__|$ROOT|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__PYTHON__|$PYTHON|g" \
        -e "s|__LLAMA_SERVER__|$LLAMA_SERVER|g" \
        -e "s|__LLM_MODEL__|$LLM_MODEL|g" \
        "$ROOT/launchd/$label.plist" > "$DEST/$label.plist"
    plutil -lint -s "$DEST/$label.plist"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    # bootout returns before the job is gone; bootstrap fails with error 5 until it is.
    for _ in $(seq 50); do
        launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1 || break
        sleep 0.2
    done
    launchctl bootstrap "gui/$UID_NUM" "$DEST/$label.plist"
    echo "started $label"
done
