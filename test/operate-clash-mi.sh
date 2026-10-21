#!/bin/bash
# Reads Clash Mi and opens About or Developer Options. Does not change proxy, TUN, or the active node.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" clash
