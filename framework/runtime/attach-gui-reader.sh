#!/bin/bash
# Skill-start hook. Reads the generic plan and attaches the macOS Intel gui.read plugin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN="$ROOT/protocol/plan.json"
PLUGIN_DIR="$ROOT/platforms/macos/intel/gui-reader"
SOURCE="$PLUGIN_DIR/main.swift"
BINARY="$PLUGIN_DIR/gui-reader"
OUT_DIR="$ROOT/dev/viewer"

if [[ ! -f "$PLAN" ]]; then
  echo "missing plan: $PLAN" >&2
  exit 1
fi

TARGET_APP="$(
  python3 - "$PLAN" "$PLUGIN_DIR/manifest.json" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
expected = {
    "id": "gui-reader",
    "platform": "macos",
    "arch": "intel",
    "capability": "gui.read",
}
for key, value in expected.items():
    if manifest.get(key) != value:
        sys.stderr.write("manifest %s must be %s\n" % (key, value))
        sys.exit(1)

step = None
for item in plan.get("steps", []):
    if item.get("action") == "attachPlugin" and item.get("capability") == "gui.read":
        step = item
        break
if step is None:
    sys.stderr.write("plan has no attachPlugin step for gui.read\n")
    sys.exit(1)

target = step.get("targetApp")
if not isinstance(target, str) or not target:
    sys.stderr.write("gui.read step is missing targetApp\n")
    sys.exit(1)
sys.stdout.write(target)
PY
)"

mkdir -p "$OUT_DIR"

build_x86_64() {
  xcrun --sdk macosx swiftc \
    -target x86_64-apple-macosx13.0 \
    -framework Cocoa \
    -framework ApplicationServices \
    -o "$BINARY" \
    "$SOURCE"
  codesign --force --sign - "$BINARY"
}

build_host() {
  xcrun --sdk macosx swiftc \
    -framework Cocoa \
    -framework ApplicationServices \
    -o "$BINARY" \
    "$SOURCE"
  codesign --force --sign - "$BINARY"
}

needs_build=0
if [[ ! -x "$BINARY" || "$SOURCE" -nt "$BINARY" ]]; then
  needs_build=1
fi

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    if [[ "$needs_build" == "1" ]]; then
      build_x86_64
    fi
    echo "running gui-reader as x86_64 under Rosetta" >&2
    exec arch -x86_64 "$BINARY" "$TARGET_APP" "$OUT_DIR"
  fi
  echo "Rosetta is not installed. Building a host-arch (arm64) binary so the read can run. The plugin package stays macos-intel." >&2
  build_host
  exec "$BINARY" "$TARGET_APP" "$OUT_DIR"
fi

if [[ "$needs_build" == "1" ]]; then
  build_x86_64
fi
echo "running gui-reader as x86_64" >&2
exec "$BINARY" "$TARGET_APP" "$OUT_DIR"
