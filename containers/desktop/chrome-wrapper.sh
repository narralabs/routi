#!/usr/bin/env bash
set -euo pipefail

n="${DISPLAY#:}"
n="${n%%.*}"
n="${n:-0}"
profile="${HOME}/chrome-profile-${n}"
mkdir -p "$profile"

# Keep Debian chromium-sandbox when the container allows user namespaces.
# Pass ROUTI_CHROME_NO_SANDBOX=1 to force --no-sandbox (last resort).
extra=()
if [ "${ROUTI_CHROME_NO_SANDBOX:-0}" = "1" ]; then
  extra+=(--no-sandbox)
fi

exec chromium \
  --user-data-dir="$profile" \
  --class=routi-chrome \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --password-store=basic \
  --hide-crash-restore-bubble \
  "${extra[@]}" \
  "$@"
