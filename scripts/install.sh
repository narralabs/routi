#!/bin/sh
# The one-line install for Routi Core:  curl -fsSL <this file's URL> | sh
#
# Downloads the latest core tarball, unpacks it to ~/.routi/core, and runs its installer,
# which handles Node, the build and the login agent. Re-running upgrades in place. The
# URL is the one thing here that changes when the project moves or is renamed.
set -e
url="${ROUTI_CORE_URL:-https://github.com/narralabs/routi/releases/latest/download/routi-core.tar.gz}"
dest="$HOME/.routi/core"

printf '\n\033[1m%s\033[0m\n' "Downloading Routi Core"
tmp="$(mktemp -d)"
if ! curl -fsSL "$url" -o "$tmp/routi-core.tar.gz"; then
  echo "Could not download $url" >&2
  echo "If you have the tarball already: tar xzf routi-core.tar.gz && cd routi-core && scripts/install-core.sh" >&2
  exit 1
fi
mkdir -p "$dest"
tar xzf "$tmp/routi-core.tar.gz" -C "$dest" --strip-components=1
rm -rf "$tmp"
exec sh "$dest/scripts/install-core.sh"
