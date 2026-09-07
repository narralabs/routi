#!/bin/sh
# Cuts a core release:  scripts/release-core.sh 0.1.9
#
# Sets the version in daemon/package.json and protocol/package.json, commits, tags
# v<version>, and pushes. The tag is what the release workflow builds from, so the
# tarball it publishes reports the same version the tag says — /health, the
# handshake and Settings → Routi Core all read the package. Run from a clean tree
# on main.
set -e
version="$1"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: $0 <major.minor.patch>" >&2; exit 1 ;;
esac
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean." >&2; exit 1; }

for pkg in daemon/package.json protocol/package.json; do
  sed -i '' "s/^  \"version\": \"[^\"]*\"/  \"version\": \"$version\"/" "$pkg"
done
git add daemon/package.json protocol/package.json
git commit -q -m "Core $version"
git tag "v$version"
git push -q origin HEAD:main "v$version"
echo "Tagged v$version. The Release workflow publishes the tarball; then attach the DMG and bump the tap:"
echo "  gh release upload v$version build/RoutiBot.dmg"
