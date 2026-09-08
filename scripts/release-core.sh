#!/bin/sh
# Cuts a core release:  scripts/release-core.sh 0.1.9
#
# Sets the version in daemon/package.json, protocol/package.json and the app's
# project.yml, commits, tags v<version>, and pushes. The tag is what the release workflow builds from, so the
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
# The app carries the same number. Its build number is the version packed into one
# integer (0.1.30 is 130, 0.2.0 is 200): Sparkle orders releases by it, so it has to
# climb across a minor bump, which the patch number alone did not. The two used to be
# bumped by hand and drifted, so a release's DMG reported the release before it.
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
build=$((major * 10000 + minor * 100 + patch))
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$version\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$build\"/" apple/project.yml
(cd apple && ./bootstrap.sh >/dev/null)
git add daemon/package.json protocol/package.json apple/project.yml apple/Routi.xcodeproj/project.pbxproj
git commit -q -m "Core $version"
git tag "v$version"
git push -q origin HEAD:main "v$version"
echo "Tagged v$version. The Release workflow publishes the tarball; then attach the app and bump the tap:"
echo "  scripts/package.sh && gh release upload v$version build/RoutiBot.dmg build/appcast.xml"
