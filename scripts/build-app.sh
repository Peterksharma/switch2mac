#!/bin/bash
# build-app.sh — build FinallyTheControllerWorks.app from the Swift package.
#
# Usage:
#   ./scripts/build-app.sh                 # ad-hoc signed (no virtual HID)
#   SIGN_IDENTITY="Developer ID Application: ..." \
#     ./scripts/build-app.sh               # full signing incl. HID entitlement
#
# The HID entitlement is profile-gated: the build picks up
# signing/FinallyTheControllerWorks.provisionprofile automatically, or set
# PROVISIONING_PROFILE to point somewhere else. The profile is checked before
# signing (scripts/check-profile.sh) because a wrong one signs cleanly and
# then gets the app killed at launch.
#
# Output: build/Finally the Controller Works.app

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Finally the Controller Works"
DEFAULT_PROFILE="signing/FinallyTheControllerWorks.provisionprofile"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
if [ -z "$PROVISIONING_PROFILE" ] && [ -f "$DEFAULT_PROFILE" ]; then
    PROVISIONING_PROFILE="$DEFAULT_PROFILE"
fi
EXE=FinallyTheControllerWorks
OUT="build/$APP_NAME.app"

swift build -c release

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/$EXE" "$OUT/Contents/MacOS/$EXE"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$OUT/Contents/Info.plist" 2>/dev/null || true
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    if [ -n "$PROVISIONING_PROFILE" ]; then
        # Full build: profile-gated HID entitlement → system-wide virtual pads.
        ./scripts/check-profile.sh "$PROVISIONING_PROFILE"
        cp "$PROVISIONING_PROFILE" "$OUT/Contents/embedded.provisionprofile"
        codesign --force --options runtime --timestamp \
            --entitlements Resources/entitlements-dev.plist \
            --sign "$SIGN_IDENTITY" "$OUT"
        # The entitlement is the whole point of this path; confirm it stuck
        # rather than trusting that codesign did what we asked.
        if ! codesign -d --entitlements - "$OUT" 2>/dev/null \
                | grep -q "com.apple.developer.hid.virtual.device"; then
            echo "error: signed bundle has no HID entitlement" >&2
            exit 1
        fi
        codesign --verify --strict --verbose=1 "$OUT"
        echo "Signed with: $SIGN_IDENTITY (virtual HID enabled)"
    else
        # Developer ID without profile: notarizable, UDP/SDL path only.
        # (Signing the restricted entitlement without an embedded profile
        # would make macOS kill the app at launch.)
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$OUT"
        echo "Signed with: $SIGN_IDENTITY (no profile: virtual HID disabled)"
    fi
else
    codesign --force --sign - "$OUT"
    echo "Ad-hoc signed (virtual HID disabled; UDP/SDL path active)"
fi

echo "Built: $OUT"
