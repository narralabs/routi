#!/usr/bin/env bash
# Brings up the display, the desktop, and a VNC server on :5900.
set -euo pipefail

cleanup() { pkill -P $$ || true; }
trap cleanup EXIT

Xvfb "$DISPLAY" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" -nolisten tcp &
# Wait for the display rather than sleeping a fixed guess.
for _ in $(seq 1 50); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.2
done

# XFCE needs a session bus; without it the panel and Thunar fail silently.
eval "$(dbus-launch --sh-syntax)"
startxfce4 &

# -shared so several viewers can watch at once; the daemon's capture is one of them.
x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -rfbport 5900 &

wait -n
