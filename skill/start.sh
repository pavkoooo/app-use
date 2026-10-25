#!/bin/bash
# One-shot start: notification broker + gui-reader attach + usage recording.
# Requires: macOS, Accessibility permission for the terminal/Cursor hosting this script,
#           /usr/bin/python3 (system), and the shipped platforms/macos/intel/gui-reader/gui-reader.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BROKER="$ROOT/framework/runtime/notification-broker.py"
ATTACH="$ROOT/framework/runtime/attach-gui-reader.sh"
BINARY="$ROOT/platforms/macos/intel/gui-reader/gui-reader"
BROKER_PID="/tmp/app-use-broker.pid"
WATCH_PID="/tmp/app-use-watcher.pid"
RECORDER_PID="/tmp/app-use-recorder.pid"
BROKER_LOG="/tmp/app-use-broker.log"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. macOS provides /usr/bin/python3 — open Terminal and retry." >&2
  exit 1
fi
if [[ ! -x "$BINARY" && "${APP_USE_BUILD:-}" != "1" ]]; then
  echo "prebuilt gui-reader missing: $BINARY" >&2
  echo "Use a full clone of this repo, or set APP_USE_BUILD=1 to compile (developer path)." >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "app-use skill currently ships a macOS Intel reader only." >&2
  exit 1
fi

broker_up() {
  python3 -c 'import socket; socket.create_connection(("127.0.0.1", 47653), 1).close()' >/dev/null 2>&1
}

stop_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  rm -f "$file"
  [[ -n "${pid:-}" ]] || return 0
  kill "$pid" 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
}

stop_port() {
  local pids pid _
  pids="$(lsof -nP -iTCP:47653 -sTCP:LISTEN -t 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 0
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! broker_up; then
      return 0
    fi
    sleep 0.1
  done
  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done
}

stop_pid_file "$RECORDER_PID"
stop_pid_file "$WATCH_PID"
stop_pid_file "$BROKER_PID"
stop_port

: > "$BROKER_LOG"
pid="$(
  python3 - "$BROKER" "$ROOT" "$BROKER_LOG" <<'PY'
import subprocess
import sys
proc = subprocess.Popen(
    [sys.executable, sys.argv[1], sys.argv[2]],
    stdout=open(sys.argv[3], "a"),
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
print(proc.pid)
PY
)"
echo "$pid" > "$BROKER_PID"

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if broker_up; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != "1" ]]; then
  echo "notification broker did not start" >&2
  cat "$BROKER_LOG" >&2 || true
  exit 1
fi

"$ATTACH"

python3 - <<'PY'
import urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:47653/record/start",
    data=b"{}",
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=20) as response:
    if response.status != 200:
        raise SystemExit("recording did not start")
PY

echo "app-use ready: broker http://127.0.0.1:47653  viewer $ROOT/dev/viewer/index.html"
echo "Grant Accessibility to this Terminal/Cursor if reads return empty trees."
