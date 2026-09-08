#!/bin/bash
# Builds the iPhone and iPad app for the App Store and uploads it to TestFlight:
#
#   scripts/testflight.sh
#
# Signs against the Narra Labs team through the Apple ID saved in Xcode
# (westoque@narralabs.com), archives for iOS devices, and hands the archive to
# App Store Connect. Two things must be true first: that account is signed in under
# Xcode > Settings > Accounts with no expired accounts beside it — the export walks
# every saved account and a rejected one stops it — and App Store Connect has an app
# with bundle id com.narralabs.routi. The version and build number are the ones the
# release script set; upload the same version twice and App Store Connect refuses the
# second, so cut a release first.
#
#   scripts/testflight.sh --upload-only
#
# uploads the archive from the last run without rebuilding — for when the archive
# was fine and only the upload failed, which is what an expired Apple ID session
# looks like ("No Accounts with App Store Connect Access": sign the account back in
# under Xcode > Settings > Accounts, then run this).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$root/build/Routi-iOS.xcarchive"
out="$root/build/ios-upload"

cd "$root/apple"
if [ "${1:-}" = "--upload-only" ]; then
  [ -d "$archive" ] || { echo "No archive at $archive; run without --upload-only first." >&2; exit 1; }
else
  ./bootstrap.sh --ios
  echo "Archiving for iOS"
  rm -rf "$archive"
  # The filter keeps the output readable; the status has to come from xcodebuild, not
  # from grep, or a failed build reads as a success.
  xcodebuild archive -scheme Routi -destination 'generic/platform=iOS' -configuration Release \
    -archivePath "$archive" -allowProvisioningUpdates 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
  [ "${PIPESTATUS[0]:-0}" -eq 0 ] || { ./bootstrap.sh >/dev/null; exit 1; }
fi

echo "Uploading to App Store Connect"
rm -rf "$out"
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$root/packaging/testflight/ExportOptions.plist" \
  -exportPath "$out" -allowProvisioningUpdates 2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload succeeded"
status="${PIPESTATUS[0]:-0}"

# Back to the Mac-only project, which is what the repository carries. A plain
# bootstrap does that by itself; a git checkout here threw away uncommitted edits.
./bootstrap.sh >/dev/null
[ "$status" -eq 0 ] || { echo "The upload failed; the archive is kept for --upload-only." >&2; exit "$status"; }
