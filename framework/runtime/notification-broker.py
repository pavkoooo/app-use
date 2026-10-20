#!/usr/bin/env python3
"""Local notification broker. Wire messages follow protocol/notifications.schema.json."""

import json
import os
import queue
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 47653
ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
LOCK = threading.Lock()
LISTENERS = {}
VIEWERS = []
SUBJECT = "gui.changed"


def plan_target():
    path = os.path.join(ROOT, "protocol", "plan.json")
    plan = json.load(open(path, encoding="utf-8"))
    for step in plan.get("steps", []):
        if step.get("action") == "attachPlugin" and step.get("capability") == "gui.read":
            target = step.get("targetApp")
            if isinstance(target, str) and target:
                return target
    raise RuntimeError("plan has no gui.read target")


def reader_command(target, output):
    binary = os.path.join(ROOT, "platforms", "macos", "intel", "gui-reader", "gui-reader")
    if os.uname().machine == "arm64":
        try:
            subprocess.check_call(["arch", "-x86_64", "/usr/bin/true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return ["arch", "-x86_64", binary, target, output]
        except (OSError, subprocess.CalledProcessError):
            pass
    return [binary, target, output]


def read_snapshot():
    target = plan_target()
    output = os.path.join(ROOT, "dev", "viewer")
    os.makedirs(output, exist_ok=True)
    subprocess.run(reader_command(target, output), check=True, timeout=45)
    with open(os.path.join(output, "snapshot.json"), encoding="utf-8") as handle:
        return handle.read()


def fanout(event):
    subject = event.get("subject")
    with LOCK:
        targets = list(VIEWERS)
        for info in LISTENERS.values():
            if subject in info["subjects"]:
                targets.extend(list(info["queues"]))
    for item in targets:
        item.put(event)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path == "/listen":
            self.handle_listen(unregister=False)
            return
        if self.path == "/unlisten":
            self.handle_listen(unregister=True)
            return
        if self.path == "/events":
            self.handle_publish()
            return
        self.send_json(404, {"error": "not found"})

    def handle_listen(self, unregister):
        try:
            body = self.read_body()
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid json"})
            return
        name = body.get("listener") or body.get("name")
        subjects = body.get("subjects")
        if not isinstance(name, str) or not name:
            self.send_json(400, {"error": "listener name is required"})
            return
        if subjects is None and not unregister:
            self.send_json(400, {"error": "subjects are required"})
            return
        if subjects is not None and (
            not isinstance(subjects, list) or not subjects or any(item != SUBJECT for item in subjects)
        ):
            self.send_json(400, {"error": "subjects must be gui.changed"})
            return
        with LOCK:
            if unregister:
                info = LISTENERS.get(name)
                if info is None:
                    remaining = []
                elif subjects is None:
                    LISTENERS.pop(name, None)
                    remaining = []
                else:
                    info["subjects"].difference_update(subjects)
                    remaining = sorted(info["subjects"])
                    if not info["subjects"]:
                        LISTENERS.pop(name, None)
                self.send_json(200, {"operation": "unregister", "listener": name, "subjects": remaining})
                return
            info = LISTENERS.setdefault(name, {"subjects": set(), "queues": []})
            info["subjects"].update(subjects)
            current = sorted(info["subjects"])
        self.send_json(200, {"operation": "register", "listener": name, "subjects": current})

    def handle_publish(self):
        try:
            event = self.read_body()
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid json"})
            return
        payload = event.get("payload")
        if event.get("subject") != SUBJECT or not isinstance(payload, dict):
            self.send_json(400, {"error": "expected gui.changed with a snapshot payload"})
            return
        if not payload.get("app") or not payload.get("capturedAt") or not isinstance(payload.get("tree"), dict):
            self.send_json(400, {"error": "payload must be a GUI snapshot"})
            return
        fanout(event)
        self.send_json(202, {"subject": SUBJECT})

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/snapshot":
            self.handle_snapshot()
            return
        if path == "/events":
            listener = None
            for part in query.split("&"):
                if part.startswith("listener="):
                    listener = part.split("=", 1)[1]
            self.handle_events(listener)
            return
        self.send_json(404, {"error": "not found"})

    def handle_snapshot(self):
        try:
            raw = read_snapshot().encode("utf-8")
        except Exception as exc:
            message = json.dumps({"error": str(exc)}).encode("utf-8")
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_events(self, listener):
        item = queue.Queue()
        with LOCK:
            if listener:
                info = LISTENERS.get(listener)
                if info is None:
                    self.send_json(404, {"error": "listener is not registered"})
                    return
                info["queues"].append(item)
            else:
                VIEWERS.append(item)
        self.close_connection = False
        self.protocol_version = "HTTP/1.0"
        header = (
            "HTTP/1.0 200 OK\r\n"
            "Content-Type: text/event-stream\r\n"
            "Cache-Control: no-cache\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "\r\n"
        )
        try:
            self.connection.sendall(header.encode("ascii"))
            self.connection.sendall(b": ready\n\n")
            while True:
                try:
                    event = item.get(timeout=10)
                except queue.Empty:
                    self.connection.sendall(b": keepalive\n\n")
                    continue
                data = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
                block = ("event: %s\ndata: %s\n\n" % (event["subject"], data)).encode("utf-8")
                self.connection.sendall(block)
        except (BrokenPipeError, ConnectionResetError, OSError) as exc:
            sys.stderr.write("event stream closed: %s\n" % exc)
        finally:
            with LOCK:
                if listener and listener in LISTENERS:
                    queues = LISTENERS[listener]["queues"]
                    if item in queues:
                        queues.remove(item)
                elif item in VIEWERS:
                    VIEWERS.remove(item)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write("notification broker on http://%s:%d\n" % (HOST, PORT))
    server.serve_forever()


if __name__ == "__main__":
    main()
