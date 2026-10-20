#!/bin/bash
# Starts the skill by running the gui.read attach hook.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/framework/runtime/attach-gui-reader.sh"
