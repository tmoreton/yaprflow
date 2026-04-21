#!/usr/bin/env bash
# Create a signed, notarized, and stapled DMG from a .app bundle.
# Usage: scripts/notarize-dmg.sh <path-to-app> [output-dmg]

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <path-to-app> [output-dmg]"
    echo "Example: $0 /Users/tmoreton/Desktop/yaprflow.app"
    echo "Example: $0 /Users/tmoreton/Desktop/yaprflow.app ./yaprflow.dmg"
    exit 1
fi

APP="$1"
DMG="${2:-$(pwd)/yaprflow.dmg}"
KEYCHAIN_PROFILE="notary-yaprflow"
SIGNING_IDENTITY="Developer ID Application: Tim Moreton (GVXC5FQ2RP)"

if [ ! -d "$APP" ]; then
    echo "Error: .app not found: $APP"
    exit 1
fi

echo "==> Creating DMG..."
rm -f "$DMG"
hdiutil create -volname Yaprflow -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

echo "==> Submitting for notarization (this can take 1-5 min)..."
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$DMG"

echo "==> Verifying..."
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo ""
echo "Done: $DMG"
du -sh "$DMG"
