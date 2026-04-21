#!/usr/bin/env bash
# Archives yaprflow for Release and packages it into a DMG.
# Requires the Models/ folder to be present (run scripts/fetch-models.sh first).

set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/yaprflow.xcodeproj"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)/build"
ARCHIVE="$BUILD_DIR/yaprflow.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG="$BUILD_DIR/yaprflow.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild -project "$PROJECT" -scheme yaprflow -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    archive

cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>mac-application</string>
    <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

hdiutil create -volname Yaprflow -srcfolder "$EXPORT_DIR/yaprflow.app" \
    -ov -format UDZO "$DMG"

echo "Done: $DMG"
du -sh "$DMG"
