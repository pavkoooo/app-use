#!/bin/bash
# Reads ChatGPT and clicks a visible sign-in control. Does not type or send a prompt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" chatgpt
