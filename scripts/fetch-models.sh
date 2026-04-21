#!/usr/bin/env bash
# Fetches the Parakeet TDT 0.6B v2 Core ML model into ./Models/.
# Tries this repo's GitHub Release (models-v2) first, falls back to HuggingFace.
# Run once after cloning the repo.

set -euo pipefail

REPO_SLUG="tmoreton/yaprflow"
MODELS_TAG="models-v2"
TARBALL="parakeet-tdt-0.6b-v2.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Models/parakeet-tdt-0.6b-v2"

if [ -f "$DEST/parakeet_vocab.json" ] && [ -d "$DEST/Encoder.mlmodelc" ]; then
    echo "Models already present at $DEST"
    exit 0
fi

mkdir -p "$(dirname "$DEST")"

release_url="https://github.com/$REPO_SLUG/releases/download/$MODELS_TAG/$TARBALL"
tmp_tar="$(mktemp -t yaprflow-models.XXXXXX.tar.gz)"
trap 'rm -f "$tmp_tar"' EXIT

echo "Trying GitHub Release: $release_url"
if curl -fsSL --retry 3 -o "$tmp_tar" "$release_url"; then
    echo "Extracting…"
    tar xzf "$tmp_tar" -C "$(dirname "$DEST")"
    echo "Done: $DEST"
    du -sh "$DEST"
    exit 0
fi

echo "GitHub Release unavailable — falling back to HuggingFace."
if ! command -v hf >/dev/null 2>&1; then
    echo "error: 'hf' (HuggingFace CLI) not installed. brew install huggingface-cli" >&2
    echo "       Or upload $TARBALL to $REPO_SLUG release tag $MODELS_TAG." >&2
    exit 1
fi

HF_REPO="FluidInference/parakeet-tdt-0.6b-v2-coreml"

# Bypass HF's 'xet' CDN (cas-bridge.xethub.hf.co), which is unreachable on
# some networks (Errno 65 'No route to host'). Forces the standard LFS path.
export HF_HUB_DISABLE_XET=1

hf download "$HF_REPO" \
    --include "Preprocessor.mlmodelc/*" \
              "Encoder.mlmodelc/*" \
              "Decoder.mlmodelc/*" \
              "JointDecision.mlmodelc/*" \
              "parakeet_vocab.json" \
    --local-dir "$DEST"

rm -rf "$DEST/.cache"

echo "Done: $DEST"
du -sh "$DEST"
