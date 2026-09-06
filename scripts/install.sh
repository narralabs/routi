#!/bin/sh
# The one-line install for Krog Core:  curl -fsSL <this file's URL> | sh
#
# Downloads the latest core tarball, unpacks it to ~/.krog/core, and runs its installer,
# which handles Node, the build and the login agent. Re-running upgrades in place. The
# URL is the one thing here that changes when the project moves or is renamed.
set -e
url="${KROG_CORE_URL:-https://github.com/narralabs/krog/releases/latest/download/krog-core.tar.gz}"
dest="$HOME/.krog/core"

printf '\n\033[1m%s\033[0m\n' "Downloading Krog Core"
tmp="$(mktemp -d)"
if ! curl -fsSL "$url" -o "$tmp/krog-core.tar.gz"; then
  echo "Could not download $url" >&2
  echo "If you have the tarball already: tar xzf krog-core.tar.gz && cd krog-core && scripts/install-core.sh" >&2
  exit 1
fi
mkdir -p "$dest"
tar xzf "$tmp/krog-core.tar.gz" -C "$dest" --strip-components=1
rm -rf "$tmp"
exec sh "$dest/scripts/install-core.sh"
