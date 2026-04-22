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

echo "==> Staging app..."
STAGE="$(mktemp -d -t yaprflow-dmg.XXXXXX)"
RW_DMG="$STAGE/yaprflow-rw.dmg"
MOUNT_DIR="$STAGE/mnt"
mkdir -p "$MOUNT_DIR"
trap '
    if mount | grep -q "$MOUNT_DIR"; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
    rm -rf "$STAGE"
' EXIT

ditto "$APP" "$STAGE/yaprflow.app"
SIZE_MB=$(( $(du -sm "$STAGE/yaprflow.app" | awk '{print $1}') + 50 ))

echo "==> Creating ${SIZE_MB}MB read-write DMG..."
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname Yaprflow -ov "$RW_DMG"

echo "==> Attaching under /tmp (bypasses /Volumes TCC protection)..."
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen

echo "==> Copying app into DMG..."
ditto "$STAGE/yaprflow.app" "$MOUNT_DIR/yaprflow.app"

echo "==> Detaching..."
hdiutil detach "$MOUNT_DIR" -quiet

echo "==> Converting to compressed read-only DMG..."
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG"

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
