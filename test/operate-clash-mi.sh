#!/bin/bash
# Reads every visible Clash Mi label on the main window, then opens About.
# Does not change proxy, TUN, or the active node.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" clash
