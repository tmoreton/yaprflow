#!/usr/bin/env bash
# Fetches the Parakeet EOU 160ms Core ML model into ./Models/.
# Tries this repo's GitHub Release (models-v1) first, falls back to HuggingFace.
# Run once after cloning the repo.

set -euo pipefail

REPO_SLUG="tmoreton/yaprflow"
MODELS_TAG="models-v1"
TARBALL="parakeet-eou-160ms.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Models/parakeet-realtime-eou-120m-coreml"
FINAL="$DEST/160ms"

if [ -f "$FINAL/vocab.json" ] && [ -d "$FINAL/streaming_encoder.mlmodelc" ]; then
    echo "Models already present at $FINAL"
    exit 0
fi

mkdir -p "$DEST"

release_url="https://github.com/$REPO_SLUG/releases/download/$MODELS_TAG/$TARBALL"
tmp_tar="$(mktemp -t yaprflow-models.XXXXXX.tar.gz)"
trap 'rm -f "$tmp_tar"' EXIT

echo "Trying GitHub Release: $release_url"
if curl -fsSL --retry 3 -o "$tmp_tar" "$release_url"; then
    echo "Extracting…"
    tar xzf "$tmp_tar" -C "$DEST"
    echo "Done: $FINAL"
    du -sh "$FINAL"
    exit 0
fi

echo "GitHub Release unavailable — falling back to HuggingFace."
if ! command -v hf >/dev/null 2>&1; then
    echo "error: 'hf' (HuggingFace CLI) not installed. brew install huggingface-cli" >&2
    echo "       Or upload $TARBALL to $REPO_SLUG release tag $MODELS_TAG." >&2
    exit 1
fi

HF_REPO="FluidInference/parakeet-realtime-eou-120m-coreml"

hf download "$HF_REPO" \
    --include "160ms/streaming_encoder.mlmodelc/*" \
    --local-dir "$DEST"

hf download "$HF_REPO" \
    --include "160ms/decoder.mlmodelc/*" \
    "160ms/joint_decision.mlmodelc/*" \
    "160ms/vocab.json" \
    --local-dir "$DEST"

rm -rf "$DEST/.cache"

echo "Done: $FINAL"
du -sh "$FINAL"
