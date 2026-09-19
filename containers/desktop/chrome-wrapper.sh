#!/usr/bin/env bash
set -euo pipefail

n="${DISPLAY#:}"
n="${n%%.*}"
n="${n:-0}"
profile="${HOME}/.chromium-:${n}"
inner=$((19222 + n - 99))
outer=$((9222 + n - 99))

# Dock and agent use the same profile, debugging endpoint, and browser process.
if ! pgrep -f "TCP-LISTEN:$outer," >/dev/null 2>&1; then
  socat TCP-LISTEN:$outer,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:$inner >/dev/null 2>&1 &
fi
mkdir -p "$profile"

# Keep Debian chromium-sandbox when the container allows user namespaces.
# Pass ROUTI_CHROME_NO_SANDBOX=1 to force --no-sandbox (last resort).
extra=()
if [ "${ROUTI_CHROME_NO_SANDBOX:-0}" = "1" ]; then
  extra+=(--no-sandbox)
fi

exec chromium \
  --user-data-dir="$profile" \
  --remote-debugging-port="$inner" \
  --class=routi-chrome \
  --start-maximized \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --password-store=basic \
  --hide-crash-restore-bubble \
  "${extra[@]}" \
  "$@"
