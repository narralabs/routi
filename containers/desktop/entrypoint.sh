#!/usr/bin/env bash
# Holds the desktop machine open. Screens are started per bot by `screenctl`.
#
# Nothing runs at boot on purpose: a container with no bots on it should cost almost
# nothing, and a bot that never opens its screen should never pay for one.
set -euo pipefail

mkdir -p /tmp/krog-screens "$HOME/Downloads"

cleanup() { pkill -P $$ || true; }
trap cleanup EXIT

# There is no long-running service to wait on, so hold the container open.
sleep infinity
