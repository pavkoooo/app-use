#!/bin/bash
# Clicks a nested View > Sort By option in Finder, verifies the checkmark
# moved, and restores the original sort. Exercises opening intermediate
# submenus before clicking a nested item.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"
exec python3 "$ROOT/test/operate-gui.py" menus
