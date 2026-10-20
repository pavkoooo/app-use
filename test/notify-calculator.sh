#!/bin/bash
# Starts the skill, registers a second listener, presses 1, and checks both streams.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  if grep -q -e "watching with AXObserver" -e "polling for UI changes" /tmp/app-use-watcher.log 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.25
done
if [[ "$ready" != "1" ]]; then
  echo "gui watcher did not become ready" >&2
  cat /tmp/app-use-watcher.log >&2 || true
  exit 1
fi

python3 - "$ROOT" <<'PY'
import json
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

base = "http://127.0.0.1:47653"
received = {"viewer": [], "probe": []}
stop = threading.Event()


def request(method, path, body=None, timeout=20):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json"}
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def display_text(payload):
    found = []

    def walk(node):
        texts = node.get("texts") or []
        if "main display" in texts:
            for text in texts:
                if text in ("main display", "text") or text.startswith("_NS:"):
                    continue
                found.append(text)
        for child in node.get("children") or []:
            walk(child)

    walk((payload or {}).get("tree") or {})
    return found[0] if found else ""


def read_sse(path, key):
    try:
        sock = socket.create_connection(("127.0.0.1", 47653), 5)
        sock.sendall(("GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" % path).encode("ascii"))
        sock.settimeout(0.5)
        buf = b""
        header_done = False
        while not stop.is_set():
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf += chunk
            if not header_done:
                if b"\r\n\r\n" not in buf:
                    continue
                buf = buf.split(b"\r\n\r\n", 1)[1]
                header_done = True
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                data_lines = []
                for raw in block.decode("utf-8", "replace").splitlines():
                    if raw.startswith("data:"):
                        data_lines.append(raw[5:].lstrip())
                if not data_lines:
                    continue
                try:
                    received[key].append(json.loads("".join(data_lines)))
                except json.JSONDecodeError as exc:
                    received[key].append({"error": str(exc)})
        sock.close()
    except Exception as exc:
        received[key].append({"error": str(exc)})


status, _ = request("POST", "/listen", {"listener": "probe", "subjects": ["gui.changed"]})
if status != 200:
    sys.stderr.write("register failed: %s\n" % status)
    sys.exit(1)

threads = [
    threading.Thread(target=read_sse, args=("/events", "viewer"), daemon=True),
    threading.Thread(target=read_sse, args=("/events?listener=probe", "probe"), daemon=True),
]
for thread in threads:
    thread.start()
time.sleep(0.4)

before = json.loads(request("GET", "/snapshot", timeout=40)[1].decode("utf-8"))
old_display = display_text(before)
stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

subprocess.check_call([
    "osascript",
    "-e", 'tell application "Calculator" to activate',
    "-e", "delay 0.2",
    "-e", 'tell application "System Events" to keystroke "1"',
])


def matching(events):
    hits = []
    for event in events:
        if event.get("subject") != "gui.changed":
            continue
        payload = event.get("payload") or {}
        shown = display_text(payload)
        captured = payload.get("capturedAt") or ""
        if captured >= stamp and shown and shown != old_display:
            hits.append(shown)
    return hits


deadline = time.time() + 12
viewer_hits = []
probe_hits = []
while time.time() < deadline:
    viewer_hits = matching(received["viewer"])
    probe_hits = matching(received["probe"])
    if viewer_hits and probe_hits:
        break
    time.sleep(0.1)

stop.set()
try:
    request("POST", "/unlisten", {"listener": "probe"})
except urllib.error.URLError:
    pass

if not viewer_hits or not probe_hits:
    sys.stderr.write("old display: %s\n" % old_display)
    sys.stderr.write("viewer: %s\n" % json.dumps(received["viewer"])[:2000])
    sys.stderr.write("\nprobe: %s\n" % json.dumps(received["probe"])[:2000])
    sys.exit(1)

print("ok: viewer saw %s; probe saw %s" % (viewer_hits[-1], probe_hits[-1]))
PY
