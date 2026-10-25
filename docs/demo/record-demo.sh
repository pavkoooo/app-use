#!/bin/bash
# Record an end-to-end app-use demo (real operations while screencapture runs).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_MOV="$ROOT/docs/demo/app-use-demo.mov"
OUT_MP4="$ROOT/docs/demo/app-use-demo.mp4"
STORE_MP4="$HOME/Library/Application Support/Cursor/AgentStores/cursor_agent_stores/bc-93621f83-fe30-4d69-8e23-8e978d98c2a4/files/media/app-use-demo.mp4"
SECONDS_REC="${1:-70}"

mkdir -p "$ROOT/docs/demo" "$(dirname "$STORE_MP4")"
rm -f "$OUT_MOV" "$OUT_MP4"

echo "recording ${SECONDS_REC}s → $OUT_MOV"
screencapture -x -k -V "$SECONDS_REC" -v "$OUT_MOV" &
REC_PID=$!
sleep 2

cleanup() {
  wait "$REC_PID" 2>/dev/null || true
}
trap cleanup EXIT

open -a Calculator || true
sleep 1

# Bring Terminal/activity into view by opening the HTML viewer
open "$ROOT/dev/viewer/index.html" || true
sleep 1

"$ROOT/skill/start.sh"

python3 - <<'PY'
import json, time, urllib.request

BASE = "http://127.0.0.1:47653"

def req(method, path, body=None, timeout=90):
    data = None if body is None else json.dumps(body).encode()
    headers = {} if body is None else {"Content-Type": "application/json"}
    r = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read().decode())

session = {
    "steps": [{
        "id": "attach-gui-reader",
        "action": "attachPlugin",
        "capability": "gui.read",
        "targetApp": "calculator",
    }],
    "listener": {
        "operation": "register",
        "listener": "demo",
        "subjects": ["gui.changed"],
    },
}
req("POST", "/session", session)
time.sleep(1.5)
snap = req("GET", "/snapshot")
print("read app=%s" % snap.get("app"))

def walk(node, pred, found):
    if pred(node):
        found.append(node)
    for c in node.get("children") or []:
        walk(c, pred, found)

def find_button(tree, label):
    found = []
    walk(tree, lambda n: n.get("role") == "AXButton" and label in (n.get("texts") or []) and n.get("id"), found)
    return found[0] if found else None

def display_text(payload):
    found = []
    def w(node):
        texts = node.get("texts") or []
        if "main display" in texts:
            for t in texts:
                if t not in ("main display", "text") and not t.startswith("_NS:"):
                    found.append(t)
        for c in node.get("children") or []:
            w(c)
    w(payload.get("tree") or {})
    return found[0] if found else ""

tree = snap.get("tree")
shown = display_text(snap)
if shown != "0":
    for label in ("all clear", "clear"):
        btn = find_button(tree, label)
        if btn:
            req("POST", "/perform", {"action": "click", "nodeId": btn["id"]})
            time.sleep(0.8)
            snap = req("GET", "/snapshot")
            tree = snap.get("tree")
            break

digit = find_button(tree, "1")
if not digit:
    raise SystemExit("button 1 missing")
req("POST", "/perform", {"action": "click", "nodeId": digit["id"]})
time.sleep(1.0)
after = req("GET", "/snapshot")
print("after click display=%s" % display_text(after))
# Refresh viewer file by re-opening
print("demo actions done")
PY

open "$ROOT/dev/viewer/index.html" || true
# Hold so the recorder captures the viewer + calculator state
sleep 8

wait "$REC_PID"
trap - EXIT

if [[ ! -f "$OUT_MOV" ]]; then
  echo "recording missing: $OUT_MOV" >&2
  exit 1
fi

echo "converting to mp4"
avconvert --source "$OUT_MOV" --preset Preset640x480 --output "$OUT_MP4" --replace 2>&1 || \
  avconvert --source "$OUT_MOV" --preset PresetHighestQuality --output "$OUT_MP4" --replace 2>&1

# If avconvert still wrote .mov semantics, ensure file exists
if [[ ! -f "$OUT_MP4" ]]; then
  # Fallback: copy mov as mp4 container name (QuickTime still plays); prefer real convert
  cp "$OUT_MOV" "$OUT_MP4"
fi

cp "$OUT_MP4" "$STORE_MP4"
ls -lh "$OUT_MOV" "$OUT_MP4" "$STORE_MP4"
file "$OUT_MP4"
echo "demo ready"
