#!/bin/bash
# notarize.sh — build, sign, notarize, and staple the app for distribution.
#
# Prerequisites (one-time):
#   1. A Developer ID Application certificate + private key in the login
#      keychain (check: security find-identity -v -p codesigning).
#   2. The Developer ID provisioning profile carrying the HID virtual-device
#      entitlement, saved as
#         signing/FinallyTheControllerWorks.provisionprofile
#      (Apple granted the entitlement to team 4BA4S6WKX7; the profile is what
#      hands it to the app. Verify with ./scripts/check-profile.sh.)
#      Without it the build still notarizes, but ships with no system-wide
#      virtual gamepads — set ALLOW_NO_HID=1 to do that deliberately.
#   3. An app-specific password from https://account.apple.com
#      (Sign-In & Security → App-Specific Passwords), stored in the keychain:
#         xcrun notarytool store-credentials ftcw-notary \
#             --apple-id "peterksharma@gmail.com" \
#             --team-id 4BA4S6WKX7 \
#             --password "<app-specific-password>"
#
# Then just run: ./scripts/notarize.sh
#
# Result: build/Finally the Controller Works.app is notarized + stapled, and
# build/FinallyTheControllerWorks.zip is ready to distribute.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Finally the Controller Works.app"
ZIP="build/FinallyTheControllerWorks.zip"
IDENTITY="Developer ID Application: Peter Sharma (4BA4S6WKX7)"
KEYCHAIN_PROFILE="ftcw-notary"
PROFILE="${PROVISIONING_PROFILE:-signing/FinallyTheControllerWorks.provisionprofile}"

# The release exists to ship the virtual-gamepad path, so an accidental
# profile-less build must not slip out as a release.
if [ ! -f "$PROFILE" ] && [ "${ALLOW_NO_HID:-0}" != "1" ]; then
    echo "error: no provisioning profile at $PROFILE" >&2
    echo "       Without it the app cannot create virtual gamepads, so games" >&2
    echo "       would still need the SDL bridge. Download the Developer ID" >&2
    echo "       profile for com.petersharma.finallythecontrollerworks, or" >&2
    echo "       re-run with ALLOW_NO_HID=1 to ship without the entitlement." >&2
    exit 1
fi

echo "==> Building signed app"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}" SIGN_IDENTITY="$IDENTITY" \
    ./scripts/build-app.sh

echo "==> Zipping for submission"
rm -f "$ZIP"
ditto -c -k --keepParent --noextattr --norsrc "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (this takes a few minutes)"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-zipping the stapled app for distribution"
# --noextattr: without it ditto shadows each file's extended attributes as an
# AppleDouble "._" entry. Finder merges those back on expand, but a user who
# unzips from the command line gets them written INSIDE the bundle, where
# they are files the signature does not account for — codesign --verify then
# fails on an app that was perfectly good. (xattr -cr can't prevent this:
# com.apple.provenance is system-protected and cannot be removed.) The staple
# ticket is a real file, Contents/CodeResources, so it is unaffected.
rm -f "$ZIP"
ditto -c -k --keepParent --noextattr --norsrc "$APP" "$ZIP"

echo "==> Generating appcast.json for the auto-updater"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
# Hosted on GitHub Releases: each release v$VERSION carries the zip and
# appcast.json as assets. The app's feed reads releases/latest/download/
# appcast.json (a stable URL), while the zip URL below is version-pinned
# so an appcast always references its own release's asset.
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/Peterksharma/switch2mac/releases/download}"
cat > build/appcast.json <<EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$DOWNLOAD_BASE/v$VERSION/FinallyTheControllerWorks.zip",
  "sha256": "$SHA",
  "notes": "Version $VERSION.",
  "minimumSystemVersion": "15.0"
}
EOF

echo "Done."
echo "  App:     $APP (notarized + stapled)"
echo "  Zip:     $ZIP"
echo "  Appcast: build/appcast.json"
echo "Publish with:"
echo "  git tag v$VERSION && git push origin main --tags"
echo "  gh release create v$VERSION \"$ZIP\" build/appcast.json \\"
echo "      --title \"v$VERSION\" --notes \"…\""
