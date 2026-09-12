#!/usr/bin/env bash
# Shared, read-only validation for Yaprflow's pinned model inventory.

YAPRFLOW_ASR_MODEL_DIR="nemotron-3.5-asr-streaming-0.6b-1120ms"
YAPRFLOW_MODEL_MANIFEST_ENTRY_COUNT=10
YAPRFLOW_UPSTREAM_SHERPA_WRAPPER_SHA256="a7ff8bbc35fc27017dc4f47271592054a2138b6e716c2abb5d8b5bdcbcf49ffd"
YAPRFLOW_SHERPA_WRAPPER_SHA256="d4731a95c3c7015f9e2f9acb024e6f1d3dfd3b1957836403b240805d9eb718a4"

yaprflow_verify_sherpa_wrapper() {
    local repository_root="$1"
    local wrapper_path="Vendor/SherpaOnnxASR/Sources/SherpaOnnx/SherpaOnnx.swift"
    local wrapper="$repository_root/$wrapper_path"

    [[ -f "$wrapper" && ! -L "$wrapper" ]] || {
        echo "error: missing reviewed sherpa-onnx Swift wrapper: $wrapper_path" >&2
        return 1
    }
    [[ "$(shasum -a 256 "$wrapper" | awk '{print $1}')" == "$YAPRFLOW_SHERPA_WRAPPER_SHA256" ]] || {
        echo "error: sherpa-onnx Swift language bridge differs from its reviewed hash" >&2
        return 1
    }
}

yaprflow_validate_model_checksum_manifest() {
    local manifest="$1"

    [[ -f "$manifest" ]] || {
        echo "error: missing model checksum manifest: $manifest" >&2
        return 1
    }
    manifest="$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")"
    awk -v expected_count="$YAPRFLOW_MODEL_MANIFEST_ENTRY_COUNT" \
        -v asr_prefix="Models/$YAPRFLOW_ASR_MODEL_DIR/" '
        NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
        (index($2, asr_prefix) != 1 && index($2, "Models/silero-vad/") != 1) ||
        $2 ~ /(^|\/)\.{1,2}(\/|$)/ || seen[$2]++ { exit 1 }
        END { if (NR != expected_count) exit 1 }
    ' "$manifest" || {
        echo "error: model checksum manifest must contain exactly ${YAPRFLOW_MODEL_MANIFEST_ENTRY_COUNT} unique, safe entries" >&2
        return 1
    }
}

yaprflow_verify_model_inventory() {
    local inventory_root="$1"
    local manifest="$2"
    local model_hash model_path actual_path inventory_diff

    yaprflow_validate_model_checksum_manifest "$manifest" || return 1
    manifest="$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")"
    [[ -d "$inventory_root/Models" ]] || {
        echo "error: $inventory_root does not contain a Models directory" >&2
        return 1
    }
    [[ -z "$(find "$inventory_root/Models" -type l -print -quit)" ]] || {
        echo "error: symbolic links are not allowed in the pinned model inventory" >&2
        return 1
    }
    [[ -z "$(find "$inventory_root/Models" ! -type d ! -type f -print -quit)" ]] || {
        echo "error: special files are not allowed in the pinned model inventory" >&2
        return 1
    }

    while read -r model_hash model_path; do
        actual_path="$inventory_root/$model_path"
        [[ -f "$actual_path" ]] || {
            echo "error: pinned model file is missing: $model_path" >&2
            return 1
        }
        [[ "$(shasum -a 256 "$actual_path" | awk '{print $1}')" == "$model_hash" ]] || {
            echo "error: pinned model checksum failed: $model_path" >&2
            return 1
        }
    done < "$manifest"

    inventory_diff="$({
        cd "$inventory_root" || exit 1
        comm -3 \
            <(awk '{print $2}' "$manifest" | LC_ALL=C sort) \
            <(find Models -type f -print | LC_ALL=C sort)
    })" || return 1
    [[ -z "$inventory_diff" ]] || {
        echo "error: model inventory does not exactly match the pinned manifest:" >&2
        printf '%s\n' "$inventory_diff" >&2
        return 1
    }
}

yaprflow_verify_native_asr_artifacts() {
    local repository_root="$1"
    local manifest="$2"
    local artifact_hash artifact_path actual_path entry_count=0

    yaprflow_verify_sherpa_wrapper "$repository_root" || return 1
    [[ -f "$manifest" ]] || {
        echo "error: missing native ASR checksum manifest: $manifest" >&2
        return 1
    }
    manifest="$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")"
    awk '
        NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
        index($2, "Vendor/SherpaOnnxASR/Artifacts/") != 1 ||
        $2 ~ /(^|\/)\.{1,2}(\/|$)/ || seen[$2]++ { exit 1 }
        END { if (NR != 10) exit 1 }
    ' "$manifest" || {
        echo "error: native ASR checksum manifest must contain exactly 10 unique, safe entries" >&2
        return 1
    }
    while read -r artifact_hash artifact_path; do
        entry_count=$((entry_count + 1))
        [[ ${#artifact_hash} -eq 64 && "$artifact_hash" != *[!0-9a-f]* ]] || {
            echo "error: malformed native ASR hash in $manifest" >&2
            return 1
        }
        case "$artifact_path" in
            Vendor/SherpaOnnxASR/Artifacts/*) ;;
            *)
                echo "error: unsafe native ASR artifact path in $manifest: $artifact_path" >&2
                return 1
                ;;
        esac
        case "/$artifact_path/" in
            *"/../"*|*"/./"*)
                echo "error: unsafe native ASR artifact path in $manifest: $artifact_path" >&2
                return 1
                ;;
        esac
        actual_path="$repository_root/$artifact_path"
        [[ -f "$actual_path" && ! -L "$actual_path" ]] || {
            echo "error: missing pinned native ASR artifact: $artifact_path" >&2
            return 1
        }
        [[ "$(shasum -a 256 "$actual_path" | awk '{print $1}')" == "$artifact_hash" ]] || {
            echo "error: native ASR artifact checksum failed: $artifact_path" >&2
            return 1
        }
    done < "$manifest"
    [[ "$entry_count" -eq 10 ]]
}
