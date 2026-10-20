#!/bin/bash
# Starts the broker, attaches the gui.read plugin, and leaves a UI watcher running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BROKER="$ROOT/framework/runtime/notification-broker.py"
ATTACH="$ROOT/framework/runtime/attach-gui-reader.sh"
BROKER_PID="/tmp/app-use-broker.pid"
WATCH_PID="/tmp/app-use-watcher.pid"
WATCH_LOG="/tmp/app-use-watcher.log"

broker_up() {
  python3 -c 'import socket; socket.create_connection(("127.0.0.1", 47653), 1).close()' >/dev/null 2>&1
}

watcher_up() {
  [[ -f "$WATCH_PID" ]] || return 1
  local pid
  pid="$(cat "$WATCH_PID")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

if ! broker_up; then
  nohup python3 "$BROKER" "$ROOT" >> /tmp/app-use-broker.log 2>&1 &
  echo $! > "$BROKER_PID"
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
    exit 1
  fi
fi

"$ATTACH"

if ! watcher_up; then
  : > "$WATCH_LOG"
  nohup "$ATTACH" watch >> "$WATCH_LOG" 2>&1 &
  echo $! > "$WATCH_PID"
fi
