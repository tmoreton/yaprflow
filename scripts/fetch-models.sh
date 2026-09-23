#!/usr/bin/env bash
# Fetches and verifies Yaprflow's shared Parakeet ASR and Silero VAD models.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/model-release.sh"

CHECKSUMS="$ROOT/scripts/model-checksums.sha256"
PARAKEET_REPO="FluidInference/parakeet-tdt-0.6b-v3-coreml"
PARAKEET_REVISION="aed02740059203c4a87495924f685de3722ae9ce"
VAD_REPO="FluidInference/silero-vad-coreml"
VAD_REVISION="724adb2158b5fa0538c528e33ba9963e977e1633"
VAD_MODEL="silero-vad-unified-256ms-v6.0.0.mlmodelc"
PARAKEET_DEST="$ROOT/Models/$YAPRFLOW_ASR_MODEL_DIR"
VAD_DEST="$ROOT/Models/silero-vad"

fail() {
    echo "error: $*" >&2
    exit 1
}

verify_component() {
    local candidate="$1"
    local component="$2"
    local expected actual model_hash model_path relative_path

    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    [[ -z "$(find "$candidate" -type l -print -quit)" ]] || return 1
    [[ -z "$(find "$candidate" ! -type d ! -type f -print -quit)" ]] || return 1

    while read -r model_hash model_path; do
        [[ "$model_path" == "Models/$component/"* ]] || continue
        relative_path="${model_path#"Models/$component/"}"
        [[ -f "$candidate/$relative_path" ]] || return 1
        [[ "$(shasum -a 256 "$candidate/$relative_path" | awk '{print $1}')" == "$model_hash" ]] \
            || return 1
    done < "$CHECKSUMS"

    expected="$(awk -v prefix="Models/$component/" \
        'index($2, prefix) == 1 { sub(prefix, "", $2); print $2 }' \
        "$CHECKSUMS" | LC_ALL=C sort)"
    actual="$(cd "$candidate" && find . -type f -print \
        | sed 's#^\./##' | LC_ALL=C sort)"
    [[ "$actual" == "$expected" ]]
}

delete_managed_directory() {
    local directory="$1"
    [[ -d "$directory" && ! -L "$directory" ]] || fail "unsafe managed model directory: $directory"
    find "$directory" -depth -delete
}

yaprflow_validate_model_checksum_manifest "$CHECKSUMS" || exit 1
command -v hf >/dev/null 2>&1 \
    || fail "'hf' is required to fetch models (brew install huggingface-cli)"
[[ ! -L "$ROOT/Models" ]] || fail "Models must not be a symbolic link"
mkdir -p "$ROOT/Models"
find "$ROOT/Models" -name '.DS_Store' -type f -delete

temporary_root="$(mktemp -d -t yaprflow-model-fetch.XXXXXX)"
cleanup() {
    if [[ -d "$temporary_root" ]]; then
        find "$temporary_root" -depth -delete
    fi
}
trap cleanup EXIT

if [[ -d "$PARAKEET_DEST" ]] && ! verify_component "$PARAKEET_DEST" "$YAPRFLOW_ASR_MODEL_DIR"; then
    echo "Existing Parakeet model is incomplete or invalid; repairing it"
    delete_managed_directory "$PARAKEET_DEST"
fi
if [[ ! -d "$PARAKEET_DEST" ]]; then
    echo "Downloading checksum-pinned Parakeet Core ML model…"
    parakeet_stage="$temporary_root/$YAPRFLOW_ASR_MODEL_DIR"
    HF_HUB_DISABLE_XET=1 hf download "$PARAKEET_REPO" \
        --revision "$PARAKEET_REVISION" \
        --include "Preprocessor.mlmodelc/*" \
        --include "Encoder.mlmodelc/*" \
        --include "Decoder.mlmodelc/*" \
        --include "JointDecision.mlmodelc/*" \
        --include "parakeet_vocab.json" \
        --local-dir "$parakeet_stage"
    if [[ -d "$parakeet_stage/.cache" ]]; then
        delete_managed_directory "$parakeet_stage/.cache"
    fi
    verify_component "$parakeet_stage" "$YAPRFLOW_ASR_MODEL_DIR" \
        || fail "downloaded Parakeet model does not match the pinned manifest"
    mv "$parakeet_stage" "$PARAKEET_DEST"
fi

if [[ -d "$VAD_DEST" ]] && ! verify_component "$VAD_DEST" "silero-vad"; then
    echo "Existing Silero VAD is incomplete or invalid; repairing it"
    delete_managed_directory "$VAD_DEST"
fi
if [[ ! -d "$VAD_DEST" ]]; then
    echo "Downloading pinned Silero VAD…"
    vad_stage="$temporary_root/silero-vad"
    hf download "$VAD_REPO" \
        --revision "$VAD_REVISION" \
        --include "config.json" \
        --include "$VAD_MODEL/*" \
        --local-dir "$vad_stage"
    if [[ -d "$vad_stage/.cache" ]]; then
        delete_managed_directory "$vad_stage/.cache"
    fi
    verify_component "$vad_stage" "silero-vad" \
        || fail "downloaded Silero VAD does not match the pinned manifest"
    mv "$vad_stage" "$VAD_DEST"
fi

yaprflow_verify_model_inventory "$ROOT" "$CHECKSUMS" "$YAPRFLOW_ASR_MODEL_DIR" \
    || fail "the local model inventory failed verification"
echo "Parakeet and Silero models are present and verified."
