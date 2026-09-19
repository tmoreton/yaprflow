#!/usr/bin/env bash
# Creates a signed Sparkle appcast and stages a release archive for upload.
# This script does not publish the paid binary. Upload the staged DMG first,
# then publish the generated appcast only after its enclosure URL is live.

set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE_PATH="${1:-}"
DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-${2:-}}"
OUTPUT_DIR="${SPARKLE_OUTPUT_DIR:-build/sparkle-update}"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.tmoreton.yaprflow}"
ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"
RELEASE_NOTES_FILE="${SPARKLE_RELEASE_NOTES_FILE:-}"

if [[ -z "$ARCHIVE_PATH" || ! -f "$ARCHIVE_PATH" ]]; then
    echo "usage: SPARKLE_DOWNLOAD_URL_PREFIX=https://updates.example/ $0 path/to/release.(dmg|zip)" >&2
    exit 2
fi
if [[ ! "$DOWNLOAD_URL_PREFIX" =~ ^https://[^[:space:]]+$ ]]; then
    echo "error: SPARKLE_DOWNLOAD_URL_PREFIX must be an HTTPS URL" >&2
    exit 2
fi
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX%/}/"

find_sparkle_tool() {
    local name="$1"
    local candidate
    if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "$SPARKLE_BIN_DIR/$name" ]]; then
        printf '%s\n' "$SPARKLE_BIN_DIR/$name"
        return 0
    fi
    candidate="build/SourcePackages/artifacts/sparkle/Sparkle/bin/$name"
    if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    while IFS= read -r candidate; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/$name" \
        -type f -print 2>/dev/null)
    return 1
}

GENERATE_APPCAST="$(find_sparkle_tool generate_appcast || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "error: Sparkle generate_appcast was not found; resolve the Sparkle package first" >&2
    exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
ARCHIVE_NAME="$(basename "$ARCHIVE_PATH")"
case "$ARCHIVE_NAME" in
    *.dmg|*.zip) ;;
    *)
        echo "error: Sparkle update archive must be a DMG or ZIP" >&2
        exit 2
        ;;
esac
cp "$ARCHIVE_PATH" "$OUTPUT_DIR/$ARCHIVE_NAME"
cp checkout/appcast.xml "$OUTPUT_DIR/appcast.xml"

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
        echo "error: release notes file not found: $RELEASE_NOTES_FILE" >&2
        exit 1
    fi
    NOTES_EXTENSION="${RELEASE_NOTES_FILE##*.}"
    cp "$RELEASE_NOTES_FILE" "$OUTPUT_DIR/${ARCHIVE_NAME%.*}.$NOTES_EXTENSION"
fi

KEY_ARGUMENTS=(--account "$KEY_ACCOUNT")
if [[ -n "$ED_KEY_FILE" ]]; then
    if [[ ! -f "$ED_KEY_FILE" ]]; then
        echo "error: SPARKLE_ED_KEY_FILE does not exist" >&2
        exit 1
    fi
    KEY_ARGUMENTS=(--ed-key-file "$ED_KEY_FILE")
fi

"$GENERATE_APPCAST" \
    "${KEY_ARGUMENTS[@]}" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --link "https://yaprflow.com/" \
    --maximum-versions 3 \
    --maximum-deltas 0 \
    "$OUTPUT_DIR"

if ! grep -q 'sparkle:edSignature=' "$OUTPUT_DIR/appcast.xml"; then
    echo "error: generated appcast does not contain an EdDSA signature" >&2
    exit 1
fi
if ! grep -q "${DOWNLOAD_URL_PREFIX}${ARCHIVE_NAME}" "$OUTPUT_DIR/appcast.xml"; then
    echo "error: generated appcast does not contain the expected download URL" >&2
    exit 1
fi

echo "==> Prepared signed Sparkle update"
echo "    Appcast: $OUTPUT_DIR/appcast.xml"
echo "    Archive: $OUTPUT_DIR/$ARCHIVE_NAME"
echo "    Upload the archive first. Publish the appcast only after the URL is live."
