#!/usr/bin/env bash
# Holds the desktop machine open. Screens are started per bot by screenctl.
set -euo pipefail

mkdir -p /tmp/routi-screens "$HOME/Downloads"

cleanup() { pkill -P $$ || true; }
trap cleanup EXIT

sleep infinity
