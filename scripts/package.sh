#!/bin/sh
# Makes the two things a person needs: the app, and the core as a source tarball with
# its installer. Run from anywhere; output lands in ./build/.
#
# Signing is decided by what this Mac has. With a "Developer ID Application" certificate
# in the keychain the app is signed with it and, if notarization credentials are stored
# under the keychain profile "krog-notary", notarized and stapled — so it opens on any
# Mac with a double-click. Without either, it is signed to run locally and the first
# launch elsewhere is right-click > Open. Either way the build succeeds and says which.
#
# One-time setup for the notarized path, on the Mac that builds:
#   1. Xcode > Settings > Accounts > your team > Manage Certificates > +
#      > Developer ID Application
#   2. xcrun notarytool store-credentials krog-notary --apple-id <you> --team-id <TEAM>
#      (asks for an app-specific password from appleid.apple.com)
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build"
mkdir -p "$out"

identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)".*/\1/')"

echo "Building the app (universal, Release)"
derived="$out/DerivedData"
if [ -n "$identity" ]; then
  echo "  signing as: $identity"
  (cd "$root/apple" && xcodebuild -scheme Krog -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--timestamp" build >/dev/null)
else
  echo "  no Developer ID Application certificate in the keychain: signing to run locally"
  (cd "$root/apple" && xcodebuild -scheme Krog -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" build >/dev/null)
fi
app="$(find "$derived/Build/Products/Release" -maxdepth 1 -name Krog.app)"
rm -f "$out/Krog.zip"
ditto -c -k --keepParent "$app" "$out/Krog.zip"

if [ -n "$identity" ]; then
  if xcrun notarytool history --keychain-profile krog-notary >/dev/null 2>&1; then
    echo "Notarizing (this waits on Apple; usually a minute or two)"
    xcrun notarytool submit "$out/Krog.zip" --keychain-profile krog-notary --wait
    xcrun stapler staple "$app"
    rm -f "$out/Krog.zip"
    ditto -c -k --keepParent "$app" "$out/Krog.zip"
    echo "  notarized and stapled: opens anywhere with a double-click"
  else
    echo "  signed with Developer ID but not notarized: no 'krog-notary' credentials stored"
    echo "  (xcrun notarytool store-credentials krog-notary ...) — first launch elsewhere is right-click > Open"
  fi
fi

echo "Packing the core"
rm -f "$out/krog-core.tar.gz"
git -C "$root" archive --format=tar.gz --prefix=krog-core/ -o "$out/krog-core.tar.gz" HEAD \
  daemon protocol containers scripts package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json README.md

echo
ls -la "$out/Krog.zip" "$out/krog-core.tar.gz"
codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)' | head -2 | sed 's/^/  /'
