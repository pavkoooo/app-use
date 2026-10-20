#!/bin/bash
# Reads Calculator through the skill and checks the live snapshot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"

python3 - "$ROOT/dev/viewer/snapshot.json" "$ROOT/dev/viewer/snapshot.js" <<'PY'
import json
import sys

snapshot_path, script_path = sys.argv[1], sys.argv[2]
snapshot = json.load(open(snapshot_path, encoding="utf-8"))

script = open(script_path, encoding="utf-8").read()
prefix = "window.SNAPSHOT = "
suffix = ";\n"
if not script.startswith(prefix) or not script.endswith(suffix):
    sys.stderr.write("snapshot.js must assign window.SNAPSHOT\n")
    sys.exit(1)
embedded = json.loads(script[len(prefix):-len(suffix)])
if embedded != snapshot:
    sys.stderr.write("snapshot.js does not match snapshot.json\n")
    sys.exit(1)

top_keys = set(snapshot)
if top_keys != {"app", "capturedAt", "tree"}:
    sys.stderr.write("snapshot keys are %s\n" % sorted(top_keys))
    sys.exit(1)
if not snapshot["app"] or not snapshot["capturedAt"]:
    sys.stderr.write("app name or capturedAt is empty\n")
    sys.exit(1)

node_keys = {"id", "role", "frame", "texts", "children"}
frame_keys = {"x", "y", "width", "height"}
texts = []
ids = []
count = 0

def walk(node, where):
    global count
    count += 1
    if set(node) != node_keys:
        sys.stderr.write("unexpected node keys at %s: %s\n" % (where, sorted(node)))
        sys.exit(1)
    node_id = node["id"]
    if not isinstance(node_id, str) or not node_id:
        sys.stderr.write("missing node id at %s\n" % where)
        sys.exit(1)
    if node_id in ids:
        sys.stderr.write("duplicate node id %s\n" % node_id)
        sys.exit(1)
    ids.append(node_id)
    frame = node["frame"]
    if set(frame) != frame_keys or any(not isinstance(frame[k], (int, float)) for k in frame_keys):
        sys.stderr.write("bad frame at %s\n" % where)
        sys.exit(1)
    if not isinstance(node["texts"], list) or any(not isinstance(item, str) or not item for item in node["texts"]):
        sys.stderr.write("bad texts at %s\n" % where)
        sys.exit(1)
    texts.extend(node["texts"])
    for index, child in enumerate(node["children"]):
        walk(child, "%s/%d" % (where, index))

walk(snapshot["tree"], "tree")
if count < 2 or not snapshot["tree"]["children"]:
    sys.stderr.write("tree is empty (%d nodes)\n" % count)
    sys.exit(1)

# Digit buttons, plus the operator labels Calculator shows on its keypad.
required = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "−", "×", "÷", "="]
missing = [label for label in required if label not in texts]
if missing:
    unique = []
    for label in texts:
        if label not in unique:
            unique.append(label)
    sys.stderr.write("missing labels: %s\n" % missing)
    sys.stderr.write("texts read:\n")
    for label in unique:
        sys.stderr.write("  %s\n" % label)
    sys.exit(1)

print("ok: %s at %s, %d nodes" % (snapshot["app"], snapshot["capturedAt"], count))
PY
