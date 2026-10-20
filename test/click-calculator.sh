#!/bin/bash
# Registers Calculator, clicks the "1" key through POST /perform, and checks the listener.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/skill/start.sh"

python3 - "$ROOT" <<'PY'
import json
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

base = "http://127.0.0.1:47653"
received = []
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


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def request(method, path, body=None, timeout=60):
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


def find_button(tree, label):
    found = []

    def walk(node):
        texts = node.get("texts") or []
        if node.get("role") == "AXButton" and label in texts and node.get("id"):
            found.append(node)
        for child in node.get("children") or []:
            walk(child)

    walk(tree or {})
    return found[0] if found else None


def snapshot():
    status, raw = request("GET", "/snapshot")
    if status != 200:
        fail("snapshot failed: %s %s" % (status, raw[:500]))
    payload = json.loads(raw.decode("utf-8"))
    if "calculator" not in (payload.get("app") or "").lower():
        fail("snapshot app is %s" % payload.get("app"))
    return payload


def perform(node_id):
    status, raw = request("POST", "/perform", {"action": "click", "nodeId": node_id})
    if status != 200:
        fail("perform %s failed: %s %s" % (node_id, status, raw[:500]))


def read_sse():
    try:
        sock = socket.create_connection(("127.0.0.1", 47653), 5)
        sock.sendall(b"GET /events?listener=viewer HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
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
                head, buf = buf.split(b"\r\n\r\n", 1)
                header_done = True
                if b" 200 " not in head.split(b"\r\n", 1)[0]:
                    received.append({"error": head.split(b"\r\n", 1)[0].decode("utf-8", "replace")})
                    return
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                data_lines = []
                for raw in block.decode("utf-8", "replace").splitlines():
                    if raw.startswith("data:"):
                        data_lines.append(raw[5:].lstrip())
                if not data_lines:
                    continue
                try:
                    received.append(json.loads("".join(data_lines)))
                except json.JSONDecodeError as exc:
                    received.append({"error": str(exc)})
        sock.close()
    except Exception as exc:
        received.append({"error": str(exc)})


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
    fail("gui watcher did not become ready")


status, _ = request("POST", "/session", session, timeout=30)
if status != 200:
    fail("register failed: %s" % status)
wait_watcher()

thread = threading.Thread(target=read_sse, daemon=True)
thread.start()
time.sleep(0.4)

first = snapshot()
digit = find_button(first["tree"], "1")
if digit is None:
    fail("no button whose text is 1")
second = snapshot()
again = find_button(second["tree"], "1")
if again is None or again["id"] != digit["id"]:
    fail("button 1 id is not stable (%s vs %s)" % (digit["id"], None if again is None else again["id"]))

current = second
if display_text(current) != "0":
    clear = find_button(current["tree"], "all clear")
    if clear is None:
        fail("no clear button")
    perform(clear["id"])
    current = snapshot()
    if display_text(current) != "0":
        fail("display after clear is %s" % display_text(current))
    digit = find_button(current["tree"], "1")
    if digit is None or digit["id"] != again["id"]:
        fail("button 1 id changed after clear")

received[:] = []
perform(digit["id"])

deadline = time.time() + 8
hits = []
while time.time() < deadline:
    hits = []
    for event in list(received):
        if event.get("subject") != "gui.changed":
            continue
        if display_text(event.get("payload") or {}) == "1":
            hits.append(event)
    if hits:
        break
    time.sleep(0.1)

after = snapshot()
stop.set()

if display_text(after) != "1":
    fail("display is %s" % display_text(after))
if not hits:
    sys.stderr.write("viewer: %s\n" % json.dumps(received)[:2000])
    fail("registered viewer did not receive gui.changed with display 1")

print("ok: clicked %s; display 1; viewer received gui.changed" % digit["id"])
PY
