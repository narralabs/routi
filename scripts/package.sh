#!/bin/sh
# Makes the two things a person needs: the app, and the core as a source tarball with
# its installer. Run from anywhere; output lands in ./build/.
#
# Signing is decided by what this Mac has. With a "Developer ID Application" certificate
# in the keychain the app is signed with it and, if notarization credentials are stored
# under the keychain profile "routi-notary", notarized and stapled — so it opens on any
# Mac with a double-click. Without either, it is signed to run locally and the first
# launch elsewhere is right-click > Open. Either way the build succeeds and says which.
#
# One-time setup for the notarized path, on the Mac that builds:
#   1. Xcode > Settings > Accounts > your team > Manage Certificates > +
#      > Developer ID Application
#   2. xcrun notarytool store-credentials routi-notary --apple-id <you> --team-id <TEAM>
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
  (cd "$root/apple" && xcodebuild -scheme Routi -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build >/dev/null)
  # ^ Xcode adds the get-task-allow debugging entitlement to any non-archive build, and
  #   Apple rejects notarization for it. Off, this is exactly what an archive would sign.
else
  echo "  no Developer ID Application certificate in the keychain: signing to run locally"
  (cd "$root/apple" && xcodebuild -scheme Routi -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" build >/dev/null)
fi
app="$(find "$derived/Build/Products/Release" -maxdepth 1 -name "Routi Bot.app")"

# A DMG, because that is what a Mac app arrives as: a window with the app and an
# Applications shortcut, named for the product. A zip downloaded as a bare file people
# did not recognise.
dmg="$out/RoutiBot.dmg"
stage="$out/dmg-stage"
rm -rf "$stage" "$dmg"; mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Routi Bot" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
rm -rf "$stage"
[ -n "$identity" ] && codesign --sign "$identity" --timestamp "$dmg" >/dev/null

if [ -n "$identity" ]; then
  # The credentials profile: the current name, or the one from before the rename.
  profile=""
  for candidate in routi-notary krog-notary; do
    if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then profile="$candidate"; break; fi
  done
  if [ -n "$profile" ]; then
    echo "Notarizing (this waits on Apple; usually a minute or two)"
    result="$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait 2>&1)"
    echo "$result" | grep -E "^ *(id|status):" | tail -2 | sed 's/^/  /'
    if ! echo "$result" | grep -q "status: Accepted"; then
      id="$(echo "$result" | grep -m1 '  id:' | awk '{print $2}')"
      echo "Apple rejected it. Reasons:" >&2
      xcrun notarytool log "$id" --keychain-profile "$profile" 2>/dev/null \
        | grep -o '"message": *"[^"]*"' | sort -u | sed 's/^/  /' >&2
      exit 1
    fi
    xcrun stapler staple "$dmg" >/dev/null
    echo "  notarized and stapled: opens anywhere with a double-click"
  else
    echo "  signed with Developer ID but not notarized: no 'routi-notary' credentials stored"
    echo "  (xcrun notarytool store-credentials routi-notary ...) — first launch elsewhere is right-click > Open"
  fi
fi

echo "Packing the core"
rm -f "$out/routi-core.tar.gz"
git -C "$root" archive --format=tar.gz --prefix=routi-core/ -o "$out/routi-core.tar.gz" HEAD \
  daemon protocol containers scripts package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json README.md

echo
ls -la "$dmg" "$out/routi-core.tar.gz"
codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)' | head -2 | sed 's/^/  /'
