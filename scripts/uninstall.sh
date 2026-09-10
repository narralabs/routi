#!/bin/sh
# Removes Routi Core from this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/uninstall.sh | sh
#
# Stops and removes the login agent, the core and its Node under ~/.routi, the desktop
# machine and image in Docker, and the API keys Routi stored in the Keychain. Your bots
# and their conversations (~/.routi/routi.db) are kept, so reinstalling brings them back.
# To remove those too, and the app:
#
#   curl -fsSL ... | sh -s -- --purge
#
# `--dry-run` says what would go without touching anything. Untouched either way:
# Docker Desktop itself, and the sign-ins that belong to the vendors' own tools —
# Claude Code's, Codex's (~/.codex), Grok's (~/.grok). Those were yours before Routi.
set -u
purge=0; dry=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    --dry-run) dry=1 ;;
    *) echo "usage: uninstall.sh [--purge] [--dry-run]" >&2; exit 1 ;;
  esac
done

label="com.narralabs.routid"
agent="$HOME/Library/LaunchAgents/$label.plist"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
# Every change goes through here, so --dry-run is the same script with the doing left
# out. Never redirect its output: the "would:" line is the whole point of a dry run.
do_() { if [ "$dry" = 1 ]; then echo "  would: $*"; else "$@"; fi; }
# Said only when something was actually done.
did() { [ "$dry" = 1 ] || echo "$1"; }

say "Stopping Routi Core"
if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  do_ launchctl bootout "gui/$(id -u)/$label" && did "Stopped the login agent."
else
  echo "No login agent is running."
fi
[ -f "$agent" ] && do_ rm -f "$agent"
if command -v brew >/dev/null 2>&1 && brew list routi-core >/dev/null 2>&1; then
  do_ brew services stop routi-core
  do_ brew uninstall routi-core && did "Removed the Homebrew package."
fi

say "Removing the desktop machine"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [ -n "$(docker ps -aq --filter name='^/routi-desktop$' 2>/dev/null)" ]; then
    do_ docker rm -f routi-desktop && did "Removed the container."
  fi
  if [ -n "$(docker images -q routi-desktop:latest 2>/dev/null)" ]; then
    do_ docker rmi routi-desktop:latest && did "Removed the image."
  fi
else
  echo "Docker is not running; nothing to remove there (or start it and run this again)."
fi

say "Removing stored API keys"
n=0
if [ "$dry" = 1 ]; then
  security find-generic-password -s Routi >/dev/null 2>&1 && echo "  would: remove Keychain items for Routi"
else
  while security delete-generic-password -s Routi >/dev/null 2>&1; do n=$((n + 1)); done
fi
[ "$dry" = 1 ] || echo "Removed $n Keychain item(s)."

say "Removing the core"
for dir in core node logs codex grok; do
  [ -e "$HOME/.routi/$dir" ] && do_ rm -rf "$HOME/.routi/$dir"
done
did "Removed ~/.routi/core, ~/.routi/node and the logs."

if [ "$purge" = 1 ]; then
  say "Removing your bots and the app"
  for path in "$HOME/.routi" "/Applications/Routi Bot.app"; do
    [ -e "$path" ] && do_ rm -rf "$path"
  done
  do_ defaults delete com.narralabs.routi 2>/dev/null || true
  did "Removed ~/.routi, the app, and its settings."
else
  echo
  echo "Kept ~/.routi/routi.db — your bots and conversations. Reinstalling brings them back;"
  echo "run with --purge to remove them and the app as well."
fi

say "Done"
