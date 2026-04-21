#!/usr/bin/env bash
# Convert an existing Xcode archive to DMG.
# Usage: scripts/archive-to-dmg.sh <path-to-xcarchive>

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <path-to-xcarchive>"
    echo "Example: $0 ~/Library/Developer/Xcode/Archives/2025-01-15/yaprflow\ 1-15-25\ 10.30\ AM.xcarchive"
    exit 1
fi

ARCHIVE="$1"
EXPORT_DIR="$(mktemp -d)"
DMG="$(pwd)/yaprflow.dmg"

echo "Exporting from archive: $ARCHIVE"

cat > "/tmp/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>mac-application</string>
    <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "/tmp/ExportOptions.plist"

echo "Creating DMG..."
rm -f "$DMG"
hdiutil create -volname Yaprflow -srcfolder "$EXPORT_DIR/yaprflow.app" \
    -ov -format UDZO "$DMG"

rm -rf "$EXPORT_DIR"

echo "Done: $DMG"
du -sh "$DMG"
