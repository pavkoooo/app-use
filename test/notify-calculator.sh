#!/bin/bash
# Starts the skill, registers Calculator the way the viewer does, and checks the listener.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"

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
session = {
    "steps": [{
        "id": "attach-gui-reader",
        "action": "attachPlugin",
        "capability": "gui.read",
        "targetApp": "calculator",
    }],
    "listener": {
        "operation": "register",
        "listener": "viewer",
        "subjects": ["gui.changed"],
    },
}


def request(method, path, body=None, timeout=20):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json"}
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


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


def collect_texts(node, texts):
    texts.extend(node.get("texts") or [])
    for child in node.get("children") or []:
        collect_texts(child, texts)


def window_frame(node):
    frames = []

    def walk(item):
        frame = item.get("frame") or {}
        frames.append(frame)
        for child in item.get("children") or []:
            walk(child)

    walk(node or {})
    return any(
        80 <= frame.get("width", 0) <= 900 and 80 <= frame.get("height", 0) <= 900
        for frame in frames
    )


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


def status_line(path):
    sock = socket.create_connection(("127.0.0.1", 47653), 5)
    sock.settimeout(2)
    sock.sendall(("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" % path).encode("ascii"))
    buf = b""
    while b"\r\n" not in buf:
        chunk = sock.recv(1024)
        if not chunk:
            break
        buf += chunk
    sock.close()
    return buf.split(b"\r\n", 1)[0].decode("utf-8", "replace")


def wait_watcher():
    deadline = time.time() + 45
    log = ""
    while time.time() < deadline:
        try:
            log = open("/tmp/app-use-watcher.log", encoding="utf-8", errors="replace").read()
        except OSError:
            log = ""
        if "Accessibility permission denied" in log:
            sys.stderr.write(log)
            sys.exit(2)
        if "watching with AXObserver" in log or "polling for UI changes" in log:
            return
        time.sleep(0.25)
    sys.stderr.write(log)
    sys.stderr.write("\ngui watcher did not become ready\n")
    sys.exit(1)


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


page_status, page = request("GET", "/")
if page_status != 200 or "注册".encode("utf-8") not in page or b"attachPlugin" not in page:
    fail("viewer page is not served with a register button")

apps_status, apps_raw = request("GET", "/apps", timeout=90)
if apps_status != 200:
    fail("app list failed: %s %s" % (apps_status, apps_raw[:500]))
apps = json.loads(apps_raw.decode("utf-8")).get("apps") or []
if not any(item.get("id") == "calculator" and item.get("name") == "Calculator" for item in apps):
    fail("Calculator is missing from %s" % json.dumps(apps)[:1000])

snap_status, snap_raw = request("GET", "/snapshot", timeout=20)
if snap_status != 409:
    fail("snapshot before register returned %s" % snap_status)

status, body = request("POST", "/session", session, timeout=30)
if status != 200:
    fail("register failed: %s %s" % (status, body[:500]))
status, _ = request("POST", "/unlisten", {"listener": "viewer", "subjects": ["gui.changed"]})
if status != 200:
    fail("unlisten failed: %s" % status)
dropped = status_line("/events?listener=viewer")
if "404" not in dropped:
    fail("dropped listener still accepted events: %s" % dropped)

status, body = request("POST", "/session", session, timeout=30)
if status != 200:
    fail("re-register failed: %s %s" % (status, body[:500]))
wait_watcher()

status, _ = request("POST", "/listen", {"listener": "probe", "subjects": ["gui.changed"]})
if status != 200:
    fail("probe register failed: %s" % status)

threads = [
    threading.Thread(target=read_sse, args=("/events?listener=viewer", "viewer"), daemon=True),
    threading.Thread(target=read_sse, args=("/events?listener=probe", "probe"), daemon=True),
]
for thread in threads:
    thread.start()
time.sleep(0.4)

snap_status, snap_raw = request("GET", "/snapshot", timeout=60)
if snap_status != 200:
    fail("snapshot failed: %s %s" % (snap_status, snap_raw[:500]))
before = json.loads(snap_raw.decode("utf-8"))
if "calculator" not in (before.get("app") or "").lower():
    fail("snapshot app is %s" % before.get("app"))
texts = []
collect_texts(before.get("tree") or {}, texts)
missing = [label for label in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] if label not in texts]
if missing or not window_frame(before.get("tree")):
    fail("snapshot is not the Calculator window (missing %s)" % missing)
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
