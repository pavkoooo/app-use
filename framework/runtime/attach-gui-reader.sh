#!/bin/bash
# Attach the shipped macOS gui-reader. Prefers the prebuilt binary (zero toolchain).
# Set APP_USE_BUILD=1 to recompile from main.swift when developing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN="$ROOT/protocol/plan.json"
PLUGIN_DIR="$ROOT/platforms/macos/intel/gui-reader"
SOURCE="$PLUGIN_DIR/main.swift"
BINARY="$PLUGIN_DIR/gui-reader"
OUT_DIR="$ROOT/dev/viewer"

MODE="once"
if [[ "${1:-}" == "watch" ]]; then
  MODE="watch"
elif [[ "${1:-}" == "apps" ]]; then
  MODE="apps"
fi

if [[ "$MODE" != "apps" ]]; then
  if [[ ! -f "$PLAN" ]]; then
    echo "missing plan: $PLAN" >&2
    exit 1
  fi
fi

require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required (macOS includes /usr/bin/python3)." >&2
    exit 1
  fi
}

require_python

TARGET_APP=""
if [[ "$MODE" != "apps" ]]; then
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
  if [[ -n "${TARGET_APP_OVERRIDE:-}" ]]; then
    TARGET_APP="$TARGET_APP_OVERRIDE"
  fi
fi

mkdir -p "$OUT_DIR"

run_reader() {
  if [[ "$MODE" == "apps" ]]; then
    exec "$@" apps
  fi
  if [[ "$MODE" == "watch" ]]; then
    exec "$@" "$TARGET_APP" "$OUT_DIR" watch
  fi
  exec "$@" "$TARGET_APP" "$OUT_DIR"
}

build_x86_64() {
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "APP_USE_BUILD=1 needs Xcode or Command Line Tools (xcrun)." >&2
    exit 1
  fi
  xcrun --sdk macosx swiftc \
    -target x86_64-apple-macosx13.0 \
    -framework Cocoa \
    -framework ApplicationServices \
    -o "$BINARY" \
    "$SOURCE"
  codesign --force --sign - "$BINARY"
}

build_host() {
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "APP_USE_BUILD=1 needs Xcode or Command Line Tools (xcrun)." >&2
    exit 1
  fi
  xcrun --sdk macosx swiftc \
    -framework Cocoa \
    -framework ApplicationServices \
    -o "$BINARY" \
    "$SOURCE"
  codesign --force --sign - "$BINARY"
}

ensure_binary() {
  if [[ -x "$BINARY" && "${APP_USE_BUILD:-}" != "1" ]]; then
    return 0
  fi
  if [[ "${APP_USE_BUILD:-}" == "1" ]]; then
    echo "APP_USE_BUILD=1: compiling gui-reader from source" >&2
    if [[ "$(uname -m)" == "arm64" ]] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
      build_host
    else
      build_x86_64
    fi
    return 0
  fi
  if [[ ! -x "$BINARY" ]]; then
    echo "prebuilt gui-reader missing at $BINARY" >&2
    echo "Re-clone the repo, or set APP_USE_BUILD=1 to compile (needs Xcode CLT)." >&2
    exit 1
  fi
}

ensure_binary

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  # Shipped binary is x86_64 (macOS Intel package). Prefer Rosetta.
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo "running gui-reader as x86_64 under Rosetta" >&2
    run_reader arch -x86_64 "$BINARY"
  fi
  if [[ "${APP_USE_BUILD:-}" == "1" ]]; then
    echo "Rosetta missing; building host-arch binary" >&2
    build_host
    run_reader "$BINARY"
  fi
  echo "Apple Silicon needs Rosetta for the shipped Intel binary, or APP_USE_BUILD=1." >&2
  exit 1
fi

echo "running gui-reader as x86_64" >&2
run_reader "$BINARY"
