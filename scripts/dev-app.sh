#!/bin/bash
# Builds the Mac app (Debug) and opens it against the dev core:
#
#   pnpm --filter routid dev:isolated     # the dev core: ~/.routi-dev, port 7172
#   scripts/dev-app.sh                    # this: build, then open on port 7172
#
# The port is passed as a launch argument, which macOS reads above the app's saved
# defaults and never writes back — so the app you use for real, which shares those
# defaults, stays pointed at your real core. A first launch can be rehearsed too:
#
#   scripts/dev-app.sh -hasCompletedSetup NO
#
# Any extra arguments are passed straight through the same way.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "Building Routi from $root ($(git -C "$root" branch --show-current), $(git -C "$root" rev-parse --short HEAD))"
cd "$root/apple"
[ -d Routi.xcodeproj ] || ./bootstrap.sh
derived="$HOME/Library/Developer/Xcode/DerivedData/Routi-dev"
xcodebuild -scheme Routi -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$derived" build 2>&1 | awk '/error:|warning: .*Routi\/|\*\* BUILD/ { print }'
app="$derived/Build/Products/Debug/Routi Bot.app"
[ -d "$app" ] || { echo "No app built." >&2; exit 1; }
# The host too, not only the port: an app that has been pointed at another Mac's
# core keeps that host in its defaults, and a dev port on that host is nothing.
open -n "$app" --args -daemonHost "${ROUTI_DEV_HOST:-127.0.0.1}" -daemonPort "${ROUTI_DEV_PORT:-7172}" "$@"
