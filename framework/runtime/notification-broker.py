#!/usr/bin/env python3
"""Local notification broker. Wire messages follow protocol/notifications.schema.json."""

import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 47653
ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
VIEWER_DIR = os.path.join(ROOT, "dev", "viewer")
ATTACH = os.path.join(ROOT, "framework", "runtime", "attach-gui-reader.sh")
WATCH_PID = "/tmp/app-use-watcher.pid"
WATCH_LOG = "/tmp/app-use-watcher.log"
LOCK = threading.Lock()
WATCH_LOCK = threading.Lock()
LISTENERS = {}
VIEWERS = []
STATE = {"target": None}
SUBJECT = "gui.changed"
WATCH_LOG_HANDLE = None


class NoTarget(Exception):
    pass


def reader_argv(target, output):
    binary = os.path.join(ROOT, "platforms", "macos", "intel", "gui-reader", "gui-reader")
    if os.uname().machine == "arm64":
        try:
            subprocess.check_call(["arch", "-x86_64", "/usr/bin/true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return ["arch", "-x86_64", binary, target, output]
        except (OSError, subprocess.CalledProcessError):
            pass
    return [binary, target, output]


def registered_target():
    with LOCK:
        return STATE.get("target")


def read_snapshot():
    target = registered_target()
    if not target:
        raise NoTarget()
    os.makedirs(VIEWER_DIR, exist_ok=True)
    subprocess.run(reader_argv(target, VIEWER_DIR), check=True, timeout=45)
    with open(os.path.join(VIEWER_DIR, "snapshot.json"), encoding="utf-8") as handle:
        return handle.read()


def perform_click(target, node_id):
    os.makedirs(VIEWER_DIR, exist_ok=True)
    subprocess.run(reader_argv(target, VIEWER_DIR) + ["perform", node_id], check=True, timeout=70)


def list_apps():
    raw = subprocess.check_output([ATTACH, "apps"], cwd=ROOT, timeout=90)
    catalog = json.loads(raw.decode("utf-8"))
    apps = catalog.get("apps")
    if not isinstance(apps, list):
        raise RuntimeError("app list is missing")
    return catalog


def valid_subjects(subjects):
    return isinstance(subjects, list) and bool(subjects) and all(item == SUBJECT for item in subjects)


def register_listener(name, subjects):
    with LOCK:
        info = LISTENERS.setdefault(name, {"subjects": set(), "queues": []})
        info["subjects"].update(subjects)
        return sorted(info["subjects"])


def _signal_watcher(pid, sig):
    try:
        os.killpg(pid, sig)
    except OSError:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def stop_watcher():
    global WATCH_LOG_HANDLE
    pid = 0
    if os.path.exists(WATCH_PID):
        try:
            pid = int(open(WATCH_PID, encoding="utf-8").read().strip() or "0")
        except (OSError, ValueError):
            pid = 0
        try:
            os.remove(WATCH_PID)
        except OSError:
            pass
    if pid > 0:
        _signal_watcher(pid, signal.SIGTERM)
        for _ in range(20):
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.1)
        else:
            _signal_watcher(pid, signal.SIGKILL)
    if WATCH_LOG_HANDLE is not None:
        try:
            WATCH_LOG_HANDLE.close()
        except OSError:
            pass
        WATCH_LOG_HANDLE = None


def start_watcher(target):
    global WATCH_LOG_HANDLE
    with WATCH_LOCK:
        stop_watcher()
        handle = open(WATCH_LOG, "w", encoding="utf-8")
        env = os.environ.copy()
        env["TARGET_APP_OVERRIDE"] = target
        proc = subprocess.Popen(
            [ATTACH, "watch"],
            stdout=handle,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=ROOT,
            start_new_session=True,
        )
        WATCH_LOG_HANDLE = handle
        with open(WATCH_PID, "w", encoding="utf-8") as pidfile:
            pidfile.write(str(proc.pid))


def fanout(event):
    subject = event.get("subject")
    with LOCK:
        targets = list(VIEWERS)
        for info in LISTENERS.values():
            if subject in info["subjects"]:
                targets.extend(list(info["queues"]))
    for item in targets:
        item.put(event)


class BrokerServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


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
        self.send_bytes(status, "application/json", data)

    def send_bytes(self, status, content_type, data):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/listen":
            self.handle_listen(unregister=False)
            return
        if path == "/unlisten":
            self.handle_listen(unregister=True)
            return
        if path == "/session":
            self.handle_session()
            return
        if path == "/events":
            self.handle_publish()
            return
        if path == "/perform":
            self.handle_perform()
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
        if subjects is not None and not valid_subjects(subjects):
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

    def handle_session(self):
        try:
            body = self.read_body()
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid json"})
            return
        target = None
        steps = body.get("steps")
        if isinstance(steps, list):
            for step in steps:
                if not isinstance(step, dict):
                    continue
                if step.get("action") == "attachPlugin" and step.get("capability") == "gui.read":
                    target = step.get("targetApp")
                    break
        if not isinstance(target, str) or not target or any(char in target for char in "\r\n\0"):
            self.send_json(400, {"error": "attachPlugin gui.read targetApp is required"})
            return
        listener = body.get("listener") if isinstance(body.get("listener"), dict) else {}
        if listener.get("operation") not in (None, "register"):
            self.send_json(400, {"error": "listener operation must be register"})
            return
        name = listener.get("listener") or "viewer"
        subjects = listener.get("subjects") or [SUBJECT]
        if not isinstance(name, str) or not name:
            self.send_json(400, {"error": "listener name is required"})
            return
        if not valid_subjects(subjects):
            self.send_json(400, {"error": "subjects must be gui.changed"})
            return
        current = register_listener(name, subjects)
        with LOCK:
            STATE["target"] = target
        try:
            start_watcher(target)
        except Exception as exc:
            self.send_json(500, {"error": str(exc)})
            return
        self.send_json(200, {
            "attached": target,
            "operation": "register",
            "listener": name,
            "subjects": current,
        })

    def handle_perform(self):
        try:
            body = self.read_body()
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid json"})
            return
        if set(body) != {"action", "nodeId"} or body.get("action") != "click":
            self.send_json(400, {"error": "gui.perform requires action click and nodeId"})
            return
        node_id = body.get("nodeId")
        if not isinstance(node_id, str) or not node_id or any(char in node_id for char in "\r\n\0"):
            self.send_json(400, {"error": "gui.perform requires action click and nodeId"})
            return
        target = registered_target()
        if not target:
            self.send_json(409, {"error": "no app registered"})
            return
        try:
            perform_click(target, node_id)
        except Exception as exc:
            self.send_json(500, {"error": str(exc)})
            return
        self.send_json(200, {"action": "click", "nodeId": node_id})

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
        if path in ("/", "/index.html"):
            self.handle_file(os.path.join(VIEWER_DIR, "index.html"), "text/html; charset=utf-8")
            return
        if path == "/snapshot.js":
            self.handle_file(os.path.join(VIEWER_DIR, "snapshot.js"), "text/javascript; charset=utf-8", empty=b"window.SNAPSHOT = null;\n")
            return
        if path == "/apps":
            self.handle_apps()
            return
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

    def handle_file(self, path, content_type, empty=None):
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            if empty is None:
                self.send_json(404, {"error": "not found"})
                return
            data = empty
        self.send_bytes(200, content_type, data)

    def handle_apps(self):
        try:
            catalog = list_apps()
        except Exception as exc:
            self.send_json(500, {"error": str(exc)})
            return
        self.send_json(200, catalog)

    def handle_snapshot(self):
        try:
            raw = read_snapshot().encode("utf-8")
        except NoTarget:
            self.send_json(409, {"error": "no app registered"})
            return
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
    server = BrokerServer((HOST, PORT), Handler)
    sys.stderr.write("notification broker on http://%s:%d\n" % (HOST, PORT))
    server.serve_forever()


if __name__ == "__main__":
    main()
