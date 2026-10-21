#!/bin/bash
# Reads System Settings and opens General or Appearance. Does not change network, privacy, or login settings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" settings
