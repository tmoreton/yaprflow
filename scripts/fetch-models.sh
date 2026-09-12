#!/usr/bin/env bash
# Fetches and verifies Yaprflow's pinned on-device ASR and VAD models.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/model-release.sh"
REPO_SLUG="tmoreton/yaprflow"
MODELS_TAG="models-nemotron-3.5-streaming-1120ms-v1"
TARBALL="nemotron-3.5-asr-streaming-0.6b-1120ms.tar.gz"
LICENSE_ASSET="OpenMDW-1.1.txt"
MODEL_LICENSE_REVISION="b26b32b34ad2edcc29a7707abb68dcfb25a538c1"
MODEL_LICENSE_URL="https://raw.githubusercontent.com/OpenMDW/OpenMDW/$MODEL_LICENSE_REVISION/1.1/LICENSE.OpenMDW-1.1"
MODEL_LICENSE_SHA256="2ab44b68365473c112f5092211a38f231cb23e50de68b75a13369adbd76a74df"
REQUIRED_NOTICE_SHA256="595c5869ca03db16d44b83966ce326addaff444ab7de32ae503a34b3b9d537b5"
SOURCE_MODEL_REVIEW_REVISION="ea30d66debe3740a08b573244286791d423d6b3e"
EXPORT_MODEL_REVISION="cba1c96ca5ef0e8393b50584ae153a79145dc492"
UPSTREAM_MODEL_NAME="sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11"
UPSTREAM_MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$UPSTREAM_MODEL_NAME.tar.bz2"
UPSTREAM_MODEL_SHA256="adbdd5e9fef87300c37cebfcfc4f1ebe56845c860c8a760af0a1dd65ce9beed3"
VAD_REPO="FluidInference/silero-vad-coreml"
VAD_REVISION="724adb2158b5fa0538c528e33ba9963e977e1633"
MODEL_NAME="nemotron-3.5-asr-streaming-0.6b-1120ms"
LEGACY_MODEL_NAME="nemotron-streaming-en-0.6b-1120ms"
VAD_NAME="silero-vad"
DEST="$ROOT/Models/$MODEL_NAME"
VAD_DEST="$ROOT/Models/$VAD_NAME"
VAD_MODEL="silero-vad-unified-256ms-v6.0.0.mlmodelc"
CHECKSUMS="$ROOT/scripts/model-checksums.sha256"
MODEL_LICENSE="$ROOT/LICENSES/$LICENSE_ASSET"
REQUIRED_NOTICE="$ROOT/NOTICE.txt"

MODEL_FILES=(
    "decoder.int8.onnx"
    "encoder.int8.onnx"
    "joiner.int8.onnx"
    "tokens.txt"
)

fail() {
    echo "error: $*" >&2
    exit 1
}

verify_model_license() {
    local license_path="$1"

    [[ -f "$license_path" ]] || fail "missing OpenMDW-1.1 license: $license_path"
    [[ "$(shasum -a 256 "$license_path" | awk '{print $1}')" == "$MODEL_LICENSE_SHA256" ]] \
        || fail "OpenMDW-1.1 license checksum failed: $license_path"
}

ensure_model_license() {
    local downloaded_license="$1"

    if [[ -L "$ROOT/LICENSES" || -L "$MODEL_LICENSE" ]]; then
        fail "managed license paths must not be symbolic links"
    fi
    if [[ -e "$MODEL_LICENSE" && ! -f "$MODEL_LICENSE" ]]; then
        fail "$MODEL_LICENSE must be a regular file"
    fi
    if [[ -f "$MODEL_LICENSE" ]]; then
        if (verify_model_license "$MODEL_LICENSE"); then
            return
        fi
        echo "Existing OpenMDW-1.1 license is invalid; restoring the pinned official copy"
    fi

    echo "Restoring OpenMDW-1.1 from its pinned official source"
    curl -fsSL --retry 3 -o "$downloaded_license" "$MODEL_LICENSE_URL" \
        || fail "could not restore OpenMDW-1.1"
    verify_model_license "$downloaded_license"
    mkdir -p "$(dirname "$MODEL_LICENSE")"
    mv "$downloaded_license" "$MODEL_LICENSE"
    verify_model_license "$MODEL_LICENSE"
}

validate_checksum_manifest() {
    yaprflow_validate_model_checksum_manifest "$CHECKSUMS" || exit 1
}

verify_asr_tree() {
    local candidate="$1"
    local model_hash model_path relative_path inventory_diff

    [[ -d "$candidate" ]] || fail "model archive did not contain $MODEL_NAME"
    [[ -z "$(find "$candidate" -type l -print -quit)" ]] \
        || fail "symbolic links are not allowed in the model archive"
    [[ -z "$(find "$candidate" ! -type d ! -type f -print -quit)" ]] \
        || fail "special files are not allowed in the model archive"

    while read -r model_hash model_path; do
        [[ "$model_path" == "Models/$MODEL_NAME/"* ]] || continue
        relative_path="${model_path#"Models/$MODEL_NAME/"}"
        [[ -f "$candidate/$relative_path" ]] \
            || fail "model archive is missing $relative_path"
        [[ "$(shasum -a 256 "$candidate/$relative_path" | awk '{print $1}')" == "$model_hash" ]] \
            || fail "model archive checksum failed for $relative_path"
    done < "$CHECKSUMS"

    inventory_diff="$(
        comm -3 \
            <(awk -v prefix="Models/$MODEL_NAME/" \
                'index($2, prefix) == 1 {print substr($2, length(prefix) + 1)}' \
                "$CHECKSUMS" | LC_ALL=C sort) \
            <(cd "$candidate" && find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)
    )"
    [[ -z "$inventory_diff" ]] \
        || fail "model archive inventory does not match the checksum manifest: $inventory_diff"
}

verify_vad_tree() {
    local candidate="$1"
    local model_hash model_path relative_path inventory_diff

    [[ -d "$candidate" ]] || fail "model inventory did not contain $VAD_NAME"
    [[ -z "$(find "$candidate" -type l -print -quit)" ]] \
        || fail "symbolic links are not allowed in the VAD model"
    [[ -z "$(find "$candidate" ! -type d ! -type f -print -quit)" ]] \
        || fail "special files are not allowed in the VAD model"

    while read -r model_hash model_path; do
        [[ "$model_path" == "Models/$VAD_NAME/"* ]] || continue
        relative_path="${model_path#"Models/$VAD_NAME/"}"
        [[ -f "$candidate/$relative_path" ]] \
            || fail "VAD model is missing $relative_path"
        [[ "$(shasum -a 256 "$candidate/$relative_path" | awk '{print $1}')" == "$model_hash" ]] \
            || fail "VAD model checksum failed for $relative_path"
    done < "$CHECKSUMS"

    inventory_diff="$(
        comm -3 \
            <(awk -v prefix="Models/$VAD_NAME/" \
                'index($2, prefix) == 1 {print substr($2, length(prefix) + 1)}' \
                "$CHECKSUMS" | LC_ALL=C sort) \
            <(cd "$candidate" && find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)
    )"
    [[ -z "$inventory_diff" ]] \
        || fail "VAD model inventory does not match the checksum manifest: $inventory_diff"
}

validate_upstream_archive() {
    local archive="$1"
    local member listing expected members

    tar -tjf "$archive" >/dev/null && tar -tvjf "$archive" >/dev/null \
        || fail "official sherpa-onnx model archive is unreadable"
    members="$(tar -tjf "$archive")"

    while IFS= read -r member; do
        case "/$member/" in
            *"/../"*|*"/./"*) fail "unsafe official model archive path: $member" ;;
        esac
        [[ "$member" != /* ]] || fail "absolute official model archive path: $member"
    done <<< "$members"

    while IFS= read -r listing; do
        case "${listing:0:1}" in
            -|d) ;;
            *) fail "links and special files are not allowed in the official model archive" ;;
        esac
    done < <(tar -tvjf "$archive")

    for expected in "${MODEL_FILES[@]}"; do
        grep -Fxq "$UPSTREAM_MODEL_NAME/$expected" <<< "$members" \
            || fail "official model archive is missing $expected"
    done
}

validate_model_archive() {
    local archive="$1"
    local member listing member_count=0 license_member_count=0 notice_member_count=0

    tar -tzf "$archive" >/dev/null && tar -tvzf "$archive" >/dev/null \
        || fail "downloaded model archive is unreadable"

    while IFS= read -r member; do
        member_count=$((member_count + 1))
        case "$member" in
            "$MODEL_NAME"|"$MODEL_NAME/"|"$MODEL_NAME/"*) ;;
            "LICENSES"|"LICENSES/") ;;
            "LICENSES/$LICENSE_ASSET")
                license_member_count=$((license_member_count + 1))
                ;;
            "NOTICE.txt")
                notice_member_count=$((notice_member_count + 1))
                ;;
            *) fail "unsafe model archive member: $member" ;;
        esac
        case "/$member/" in
            *"/../"*|*"/./"*) fail "unsafe model archive path: $member" ;;
        esac
    done < <(tar -tzf "$archive")
    [[ "$member_count" -gt 0 ]] || fail "downloaded model archive is empty"
    [[ "$license_member_count" -eq 1 ]] \
        || fail "model archive must contain exactly one LICENSES/$LICENSE_ASSET"
    [[ "$notice_member_count" -eq 1 ]] \
        || fail "model archive must contain exactly one NOTICE.txt"

    while IFS= read -r listing; do
        case "${listing:0:1}" in
            -|d) ;;
            *) fail "links and special files are not allowed in the model archive" ;;
        esac
    done < <(tar -tvzf "$archive")
}

verify_models() {
    echo "Verifying pinned model files…"
    yaprflow_verify_model_inventory "$ROOT" "$CHECKSUMS" || exit 1
}

validate_checksum_manifest
echo "Model provenance: source/model-card reviewed at $SOURCE_MODEL_REVIEW_REVISION; export pinned at $EXPORT_MODEL_REVISION"
[[ ! -L "$ROOT/Models" && ! -L "$DEST" && ! -L "$VAD_DEST" ]] \
    || fail "managed model directories must not be symbolic links"

mkdir -p "$ROOT/Models"
find "$ROOT/Models" -name '.DS_Store' -type f -delete
rm -rf "$DEST/.cache" "$VAD_DEST/.cache"
# This exact directory was used by the superseded English-only model. It is a
# managed build artifact, not user data, and cannot coexist with the manifest.
rm -rf "$ROOT/Models/$LEGACY_MODEL_NAME"

tmp_root="$(mktemp -d -t yaprflow-model-fetch.XXXXXX)"
tmp_tar="$tmp_root/$TARBALL"
tmp_stage="$tmp_root/stage"
mkdir "$tmp_stage"
trap 'rm -rf "$tmp_root"' EXIT

ensure_model_license "$tmp_root/$LICENSE_ASSET"
[[ -f "$REQUIRED_NOTICE" ]] || fail "missing required model-origin NOTICE.txt"
[[ "$(shasum -a 256 "$REQUIRED_NOTICE" | awk '{print $1}')" == "$REQUIRED_NOTICE_SHA256" ]] \
    || fail "model-origin NOTICE.txt checksum failed"

if [[ -d "$VAD_DEST" ]] && ! (verify_vad_tree "$VAD_DEST"); then
    echo "Existing Silero VAD is incomplete or invalid; repairing it"
    rm -rf "$VAD_DEST"
fi
if [[ ! -d "$VAD_DEST" ]]; then
    command -v hf >/dev/null 2>&1 \
        || fail "'hf' is required to fetch Silero VAD (brew install huggingface-cli)"
    echo "Downloading pinned Silero VAD…"
    vad_stage="$tmp_root/$VAD_NAME"
    hf download "$VAD_REPO" \
        --revision "$VAD_REVISION" \
        --include "config.json" \
        --include "$VAD_MODEL/*" \
        --local-dir "$vad_stage"
    rm -rf "$vad_stage/.cache"
    verify_vad_tree "$vad_stage"
    mv "$vad_stage" "$VAD_DEST"
fi

if [[ -f "$DEST/${MODEL_FILES[0]}" && -f "$DEST/${MODEL_FILES[1]}" \
   && -f "$DEST/${MODEL_FILES[2]}" && -f "$DEST/${MODEL_FILES[3]}" ]]; then
    if (verify_asr_tree "$DEST" && verify_models); then
        echo "Models already present and verified at $ROOT/Models"
        exit 0
    fi
    echo "Existing Nemotron model is incomplete or invalid; repairing it"
fi
rm -rf "$DEST"

release_url="https://github.com/$REPO_SLUG/releases/download/$MODELS_TAG/$TARBALL"
echo "Trying verified GitHub model mirror: $release_url"
stage_verified_mirror() {
    curl -fsSL --retry 3 -o "$tmp_tar" "$release_url" || return 1
    validate_model_archive "$tmp_tar"
    tar xzf "$tmp_tar" -C "$tmp_stage" \
        || fail "could not extract the verified GitHub model mirror"
    verify_asr_tree "$tmp_stage/$MODEL_NAME"
    verify_model_license "$tmp_stage/LICENSES/$LICENSE_ASSET"
    cmp -s "$REQUIRED_NOTICE" "$tmp_stage/NOTICE.txt" \
        || fail "model archive NOTICE.txt does not match the required origin notice"
}

# Run mirror validation in a subshell so any download, archive, checksum, or
# notice failure falls back to the independently pinned official distribution.
if ! (stage_verified_mirror); then
    echo "Mirror unavailable or invalid; downloading the pinned official sherpa-onnx export…"
    rm -f "$tmp_tar"
    rm -rf "$tmp_stage"
    mkdir "$tmp_stage"
    upstream_tar="$tmp_root/$UPSTREAM_MODEL_NAME.tar.bz2"
    upstream_stage="$tmp_root/upstream"
    curl -fsSL --retry 3 -o "$upstream_tar" "$UPSTREAM_MODEL_URL" \
        || fail "could not download the official sherpa-onnx model export"
    [[ "$(shasum -a 256 "$upstream_tar" | awk '{print $1}')" == "$UPSTREAM_MODEL_SHA256" ]] \
        || fail "official sherpa-onnx model archive checksum failed"
    validate_upstream_archive "$upstream_tar"
    mkdir -p "$upstream_stage"
    tar -xjf "$upstream_tar" -C "$upstream_stage"
    mkdir -p "$tmp_stage/$MODEL_NAME"
    for model_file in "${MODEL_FILES[@]}"; do
        cp "$upstream_stage/$UPSTREAM_MODEL_NAME/$model_file" \
            "$tmp_stage/$MODEL_NAME/$model_file"
    done
    verify_asr_tree "$tmp_stage/$MODEL_NAME"
fi

rm -rf "$DEST"
mv "$tmp_stage/$MODEL_NAME" "$DEST"
verify_models
echo "Done: $DEST"
du -sh "$DEST"
