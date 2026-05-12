#!/usr/bin/env bash
# Local dev build + install. Ad-hoc signed, replaces /Applications/yaprflow.app,
# strips Gatekeeper quarantine, relaunches. For when you're iterating on source.
# For a Developer ID release build, use scripts/release.sh instead.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Build/Products/Release/yaprflow.app"
DEST="/Applications/yaprflow.app"

cd "$ROOT"

if [ ! -d "$ROOT/Models/parakeet-tdt-0.6b-v2/Encoder.mlmodelc" ]; then
    echo "❌ Speech model missing. See CLAUDE.md → Constraints / Gotchas for the download command." >&2
    exit 1
fi

echo "==> Building yaprflow (Release, ad-hoc)…"
xcodebuild \
    -project yaprflow.xcodeproj \
    -scheme yaprflow \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

if [ ! -d "$APP" ]; then
    echo "❌ Build succeeded but .app not found at $APP" >&2
    exit 1
fi

echo "==> Quitting running yaprflow…"
osascript -e 'tell application "yaprflow" to quit' 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Launching…"
open "$DEST"

echo ""
echo "✅ Done. Look for the waveform icon in the menu bar."
