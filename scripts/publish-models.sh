#!/usr/bin/env bash
# Packages Models/parakeet-realtime-eou-120m-coreml/160ms into a tarball and
# uploads it to the 'models-v1' GitHub Release. Run once; updates in place if
# the release already exists.

set -euo pipefail

REPO_SLUG="tmoreton/yaprflow"
MODELS_TAG="models-v1"
TARBALL="parakeet-eou-160ms.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Models/parakeet-realtime-eou-120m-coreml"
STAGE="$(mktemp -d -t yaprflow-models.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

if [ ! -d "$SRC/160ms" ]; then
    echo "error: $SRC/160ms not found. Run scripts/fetch-models.sh first." >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "error: 'gh' CLI not installed. brew install gh" >&2
    exit 1
fi

tar czf "$STAGE/$TARBALL" -C "$SRC" 160ms
ls -lh "$STAGE/$TARBALL"

if gh release view "$MODELS_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "Uploading to existing release $MODELS_TAG…"
    gh release upload "$MODELS_TAG" "$STAGE/$TARBALL" --repo "$REPO_SLUG" --clobber
else
    echo "Creating release $MODELS_TAG…"
    gh release create "$MODELS_TAG" "$STAGE/$TARBALL" \
        --repo "$REPO_SLUG" \
        --title "Parakeet EOU 160ms (Core ML)" \
        --notes "Core ML bundle mirrored from FluidInference/parakeet-realtime-eou-120m-coreml for offline app builds."
fi

echo "Done."
