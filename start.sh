#!/bin/bash
# Foreground run. Login startup is the LaunchAgent in launchd/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "${PYTHON:-$ROOT/.venv/bin/python}" "$ROOT/stt_server.py"
