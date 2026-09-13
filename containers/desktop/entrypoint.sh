#!/usr/bin/env bash
# Holds the desktop machine open. Screens are started per bot by screenctl.
set -euo pipefail

mkdir -p /tmp/routi-screens "$HOME/Downloads"

cleanup() { pkill -P $$ || true; }
trap cleanup EXIT
trap 'exit 0' TERM INT

# Restart the watcher if it fails, without restarting the desktop container.
while true; do
  python3 -u /usr/local/bin/renderer-watchdog.py || true
  sleep 5
done &
wait
