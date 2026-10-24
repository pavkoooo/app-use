#!/bin/bash
# Reads the Dock strip with every item labeled, clicks the Calculator item,
# and checks the frontmost application switched. Restores the previous front app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" dock
