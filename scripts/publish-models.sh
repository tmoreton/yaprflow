#!/usr/bin/env bash
# Publishes the pinned Nemotron model mirror used by scripts/fetch-models.sh.

set -euo pipefail

REPO_SLUG="tmoreton/yaprflow"
MODELS_TAG="models-nemotron-3.5-streaming-1120ms-v1"
TARBALL="nemotron-3.5-asr-streaming-0.6b-1120ms.tar.gz"
LICENSE_ASSET="OpenMDW-1.1.txt"
SOURCE_MODEL_REVIEW_REVISION="ea30d66debe3740a08b573244286791d423d6b3e"
EXPORT_MODEL_REVISION="cba1c96ca5ef0e8393b50584ae153a79145dc492"
UPSTREAM_ARCHIVE_SHA256="adbdd5e9fef87300c37cebfcfc4f1ebe56845c860c8a760af0a1dd65ce9beed3"
VAD_REVISION="724adb2158b5fa0538c528e33ba9963e977e1633"
RELEASE_TITLE="Nemotron 3.5 multilingual streaming 0.6B 1120 ms chunk-size model (pinned mirror)"
RELEASE_NOTES="On-device multilingual streaming ASR model for Yaprflow.

Source model: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
Source model/model-card revision reviewed: ${SOURCE_MODEL_REVIEW_REVISION}
ONNX export: https://huggingface.co/csukuangfj2/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11
Exact export mirror revision: ${EXPORT_MODEL_REVISION}
Official sherpa-onnx archive SHA-256: ${UPSTREAM_ARCHIVE_SHA256}
License: OpenMDW License Agreement, version 1.1

The source model covers 40 language-locales across 35 languages. Yaprflow uses
automatic detection for the 32 locales that transcribe out of the box; the 8
adaptation-ready locales require fine-tuning and are not advertised as supported.

The archive contains the 1120 ms chunk-size INT8 encoder, decoder, joiner, and token table
without modifying their contents. The archive and release assets include the
OpenMDW-1.1 license and retained origin notice. The separate checksum manifest
also covers the MIT-licensed Silero VAD Core ML conversion at revision
${VAD_REVISION}. See model-NOTICE.txt for the notices shipped with the mirror.

The export repository does not identify the exact NVIDIA commit used for
conversion. The export revision, official archive digest, and per-file hashes
are the authoritative binary pins.

Keep older model releases intact because earlier Yaprflow builds may still
reference their assets."

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_NAME="nemotron-3.5-asr-streaming-0.6b-1120ms"
SRC="$ROOT/Models/$MODEL_NAME"
CHECKSUMS="$ROOT/scripts/model-checksums.sha256"
MODEL_NOTICE="$ROOT/scripts/model-NOTICE.txt"
REQUIRED_NOTICE="$ROOT/NOTICE.txt"
MODEL_LICENSE="$ROOT/LICENSES/$LICENSE_ASSET"
MODEL_LICENSE_SHA256="2ab44b68365473c112f5092211a38f231cb23e50de68b75a13369adbd76a74df"
REQUIRED_NOTICE_SHA256="595c5869ca03db16d44b83966ce326addaff444ab7de32ae503a34b3b9d537b5"
STAGE="$(mktemp -d -t yaprflow-models.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

[[ -f "$MODEL_NOTICE" ]] \
    || { echo "error: model notice not found at $MODEL_NOTICE" >&2; exit 1; }
[[ "$(shasum -a 256 "$REQUIRED_NOTICE" 2>/dev/null | awk '{print $1}')" == "$REQUIRED_NOTICE_SHA256" ]] \
    || { echo "error: required model-origin NOTICE.txt is missing or changed" >&2; exit 1; }
[[ ! -L "$ROOT/LICENSES" && ! -L "$MODEL_LICENSE" ]] \
    || { echo "error: managed license paths must not be symbolic links" >&2; exit 1; }
[[ -f "$MODEL_LICENSE" ]] \
    || { echo "error: OpenMDW-1.1 license not found at $MODEL_LICENSE" >&2; exit 1; }
[[ "$(shasum -a 256 "$MODEL_LICENSE" | awk '{print $1}')" == "$MODEL_LICENSE_SHA256" ]] \
    || { echo "error: OpenMDW-1.1 license checksum failed" >&2; exit 1; }
command -v gh >/dev/null 2>&1 \
    || { echo "error: 'gh' CLI not installed" >&2; exit 1; }

if gh release view "$MODELS_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "error: model release $MODELS_TAG already exists and is immutable" >&2
    echo "       Publish changed assets under a new versioned tag." >&2
    exit 1
fi
if gh api --silent "repos/$REPO_SLUG/git/ref/tags/$MODELS_TAG" >/dev/null 2>&1; then
    echo "error: model tag $MODELS_TAG already exists and is immutable" >&2
    echo "       Publish changed assets under a new versioned tag." >&2
    exit 1
fi

"$ROOT/scripts/fetch-models.sh"
[[ -f "$SRC/encoder.int8.onnx" ]] \
    || { echo "error: verified Nemotron model was not created at $SRC" >&2; exit 1; }

cp "$REQUIRED_NOTICE" "$STAGE/NOTICE.txt"
echo "Packaging verified Nemotron model → $TARBALL"
tar --exclude '.cache' --exclude '.DS_Store' -czf "$STAGE/$TARBALL" \
    -C "$ROOT/Models" "$MODEL_NAME" \
    -C "$ROOT" "LICENSES/$LICENSE_ASSET" \
    -C "$STAGE" "NOTICE.txt"
(
    cd "$STAGE"
    shasum -a 256 "$TARBALL" > "$TARBALL.sha256"
)
ls -lh "$STAGE/$TARBALL"

gh release create "$MODELS_TAG" \
    "$STAGE/$TARBALL" "$STAGE/$TARBALL.sha256" \
    "$CHECKSUMS" "$MODEL_NOTICE" "$REQUIRED_NOTICE" "$MODEL_LICENSE" \
    --repo "$REPO_SLUG" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES"

echo "Done."
