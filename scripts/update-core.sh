#!/bin/sh
# Finishes an update the running core began.
#
# routid downloads and verifies the new release, unpacks it beside itself, and runs this
# script — the new release's copy of it — detached, with the unpacked folder as the
# argument. From here on the old core is a bystander: this builds the new core in its
# own folder, swaps the two, restarts the login agent, and if the new core does not come
# up answering with its version inside ninety seconds, swaps the old one back. Nothing
# is deleted until the new core is known to work; the folder that failed is kept as
# ~/.routi/core.failed for a look.
#
# Everything printed lands in ~/.routi/logs/update.log. Lines starting "==> " are the
# stages the app shows while the old core is still alive to relay them.
set -e
staging="$1"
[ -n "$staging" ] && [ -d "$staging" ] || { echo "usage: update-core.sh <unpacked core folder>" >&2; exit 1; }
root="$HOME/.routi"
current="$root/core"
previous="$root/core.prev"
label="com.narralabs.routid"
domain="gui/$(id -u)"
port="${ROUTI_PORT:-7171}"
say() { echo "==> $1"; }

version="$(sed -n 's/^  "version": "\([^"]*\)",/\1/p' "$staging/daemon/package.json" | head -1)"
say "Building Routi Core $version"
ROUTI_INSTALL_NO_AGENT=1 sh "$staging/scripts/install-core.sh"

say "Swapping it in"
rm -rf "$previous"
[ -d "$current" ] && mv "$current" "$previous"
mv "$staging" "$current"

# The agent's plist is rewritten by the new release's installer and the core restarted
# by it, so a release that changes the agent — its PATH, say — takes effect too.
say "Restarting the core"
if ! ROUTI_INSTALL_AGENT_ONLY=1 sh "$current/scripts/install-core.sh"; then
  echo "The installer could not restart the core." >&2
fi

for _ in $(seq 1 90); do
  if curl -fs "http://127.0.0.1:$port/health" 2>/dev/null | grep -q "\"version\":\"$version\""; then
    say "Routi Core $version is running"
    exit 0
  fi
  sleep 1
done

say "The new core did not answer; putting the previous one back"
rm -rf "$root/core.failed"
mv "$current" "$root/core.failed"
if [ -d "$previous" ]; then
  mv "$previous" "$current"
  ROUTI_INSTALL_AGENT_ONLY=1 sh "$current/scripts/install-core.sh" || true
fi
say "Restored the previous core. The one that failed is in ~/.routi/core.failed"
exit 1
