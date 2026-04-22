#!/usr/bin/env bash
# Packages just Encoder.mlmodelc (the big ~445MB piece of the Parakeet TDT 0.6B v2
# Core ML bundle) into a tarball and uploads it to the 'models-v2' GitHub Release.
# The app ships with the small parts (Preprocessor/Decoder/JointDecision/vocab)
# bundled, and downloads this encoder tarball on first launch.

set -euo pipefail

REPO_SLUG="tmoreton/yaprflow"
MODELS_TAG="models-v2"
TARBALL="parakeet-v2-encoder.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Models/parakeet-tdt-0.6b-v2"
STAGE="$(mktemp -d -t yaprflow-models.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

if [ ! -d "$SRC/Encoder.mlmodelc" ]; then
    echo "error: $SRC/Encoder.mlmodelc not found. Run scripts/fetch-models.sh first." >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "error: 'gh' CLI not installed. brew install gh" >&2
    exit 1
fi

echo "Packaging $SRC/Encoder.mlmodelc → $TARBALL ..."
tar czf "$STAGE/$TARBALL" -C "$SRC" "Encoder.mlmodelc"
ls -lh "$STAGE/$TARBALL"

if gh release view "$MODELS_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "Uploading to existing release ${MODELS_TAG}..."
    gh release upload "$MODELS_TAG" "$STAGE/$TARBALL" --repo "$REPO_SLUG" --clobber
else
    echo "Creating release ${MODELS_TAG}..."
    gh release create "$MODELS_TAG" "$STAGE/$TARBALL" \
        --repo "$REPO_SLUG" \
        --title "Parakeet TDT 0.6B v2 Encoder (Core ML)" \
        --notes "Core ML Encoder.mlmodelc for FluidInference/parakeet-tdt-0.6b-v2-coreml. Downloaded on first launch by Yaprflow; small model pieces ship inside the app bundle."
fi

echo "Done."
