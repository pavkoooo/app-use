#!/bin/bash
# Reads Finder and switches view. Does not delete, move, or rename files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" finder
