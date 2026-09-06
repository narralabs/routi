#!/bin/sh
# Makes the two things a person needs: the app, and the core as a source tarball with
# its installer. Run from anywhere; output lands in ./build/.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build"
mkdir -p "$out"

echo "Building the app (universal, Release)"
derived="$out/DerivedData"
(cd "$root/apple" && xcodebuild -scheme Krog -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" build >/dev/null)
app="$(find "$derived/Build/Products/Release" -maxdepth 1 -name Krog.app)"
rm -f "$out/Krog.zip"
ditto -c -k --keepParent "$app" "$out/Krog.zip"

echo "Packing the core"
rm -f "$out/krog-core.tar.gz"
git -C "$root" archive --format=tar.gz --prefix=krog-core/ -o "$out/krog-core.tar.gz" HEAD \
  daemon protocol containers scripts package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json README.md

ls -la "$out/Krog.zip" "$out/krog-core.tar.gz"
