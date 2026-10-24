#!/bin/bash
# Starts the skill and checks that a real Calculator click is recorded.
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
received = []
stop = threading.Event()


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def request(method, path, body=None, timeout=20):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json"}
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def read_sse():
    try:
        sock = socket.create_connection(("127.0.0.1", 47653), 5)
        sock.sendall(b"GET /events?listener=usage-test HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
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
                    received.append(json.loads("".join(data_lines)))
                except json.JSONDecodeError as exc:
                    received.append({"error": str(exc)})
        sock.close()
    except Exception as exc:
        received.append({"error": str(exc)})


page_status, page = request("GET", "/")
if page_status != 200 or "开始记录".encode("utf-8") not in page or "停止记录".encode("utf-8") not in page:
    fail("viewer is missing the recording controls")

deadline = time.time() + 15
log = ""
while time.time() < deadline:
    try:
        log = open("/tmp/app-use-recorder.log", encoding="utf-8", errors="replace").read()
    except OSError:
        log = ""
    if "recording" in log:
        break
    if "could not watch input" in log or "Accessibility permission denied" in log:
        fail(log)
    time.sleep(0.2)
else:
    fail(log or "recorder did not start")

status, body = request("POST", "/listen", {
    "listener": "usage-test",
    "subjects": ["usage.recorded"],
})
if status != 200:
    fail("listen failed: %s %s" % (status, body[:300]))

thread = threading.Thread(target=read_sse, daemon=True)
thread.start()
time.sleep(0.4)

script = r'''
tell application "Calculator" to activate
delay 0.6
tell application "System Events" to tell process "Calculator"
  set frontmost to true
  set target to missing value
  set allItems to entire contents of window 1
  repeat with itemRef in allItems
    try
      if role of itemRef is "AXButton" and (name of itemRef as text) is "1" then
        set target to contents of itemRef
        exit repeat
      end if
    end try
  end repeat
  if target is missing value then error "no button 1"
  set pos to position of target
  set sz to size of target
  return ((item 1 of pos) as text) & "," & ((item 2 of pos) as text) & "," & ((item 1 of sz) as text) & "," & ((item 2 of sz) as text)
end tell
'''
try:
    raw = subprocess.check_output(["osascript", "-e", script], timeout=30, text=True).strip()
    sx, sy, sw, sh = [float(part) for part in raw.split(",")]
except (subprocess.CalledProcessError, ValueError) as exc:
    fail("calculator click failed: %s" % exc)

import ctypes
graphics = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")

class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

graphics.CGEventCreateMouseEvent.restype = ctypes.c_void_p
graphics.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
graphics.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
graphics.CFRelease.argtypes = [ctypes.c_void_p]
point = CGPoint(sx + sw / 2.0, sy + sh / 2.0)
down = graphics.CGEventCreateMouseEvent(None, 1, point, 0)
up = graphics.CGEventCreateMouseEvent(None, 2, point, 0)
graphics.CGEventPost(1, down)
time.sleep(0.05)
graphics.CGEventPost(1, up)
graphics.CFRelease(down)
graphics.CFRelease(up)

def interesting(events):
    hits = []
    for event in events:
        if event.get("subject") != "usage.recorded":
            continue
        payload = event.get("payload") or {}
        app = payload.get("app") or ""
        if "calculator" not in app.lower():
            continue
        if payload.get("kind") != "click":
            continue
        text = payload.get("targetText") or ""
        states = payload.get("stateTexts") or []
        if text == "1" and states:
            hits.append(payload)
    return hits


deadline = time.time() + 15
hits = []
while time.time() < deadline:
    hits = interesting(received)
    if hits:
        break
    time.sleep(0.1)

stop.set()
try:
    request("POST", "/unlisten", {"listener": "usage-test", "subjects": ["usage.recorded"]})
except urllib.error.URLError:
    pass

if not hits:
    brief = []
    for event in received:
        payload = (event.get("payload") or {}) if isinstance(event, dict) else {}
        app = payload.get("app") or ""
        if "calculator" not in app.lower():
            if payload.get("kind"):
                brief.append("%s %s" % (app, payload.get("kind")))
            continue
        brief.append({
            "kind": payload.get("kind"),
            "targetText": payload.get("targetText"),
            "states": len(payload.get("stateTexts") or []),
        })
    sys.stderr.write(json.dumps(brief, ensure_ascii=False)[:2000] + "\n")
    sys.exit(1)

print("ok: recorded Calculator click 1 with %d window labels" % len(hits[-1].get("stateTexts") or []))
PY