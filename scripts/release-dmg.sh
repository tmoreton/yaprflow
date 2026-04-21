#!/usr/bin/env bash
# Upload DMG to GitHub Release (creates release if doesn't exist).
# Usage: scripts/release-dmg.sh <tag> [dmg-path]

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <tag> [dmg-path]"
    echo "Example: $0 v1.0.0 build/yaprflow.dmg"
    echo "Example: $0 v1.0.0           # uses ./yaprflow.dmg"
    exit 1
fi

TAG="$1"
DMG="${2:-./yaprflow.dmg}"

if [ ! -f "$DMG" ]; then
    echo "Error: DMG not found: $DMG"
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "Error: 'gh' CLI not installed. Run: brew install gh"
    exit 1
fi

echo "Creating release $TAG with $DMG..."

# Create release if it doesn't exist, then upload
echo "gh release create \"$TAG\" \"$DMG\" --generate-notes"
gh release create "$TAG" "$DMG" --generate-notes || {
    echo "Release may already exist, trying to upload asset..."
    gh release upload "$TAG" "$DMG" --clobber
}

echo "Done: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
