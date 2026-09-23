#!/usr/bin/env bash
# Shared, read-only validation for Yaprflow's pinned model inventory.

YAPRFLOW_ASR_MODEL_DIR="parakeet-tdt-0.6b-v3"
YAPRFLOW_MODEL_MANIFEST_ENTRY_COUNT=27

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
    local selected_model_dir="${3:-}"
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
        if [[ -n "$selected_model_dir" \
           && "$model_path" != "Models/$selected_model_dir/"* \
           && "$model_path" != "Models/silero-vad/"* ]]; then
            continue
        fi
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
            <(awk -v selected="$selected_model_dir" '
                selected == "" || index($2, "Models/" selected "/") == 1 ||
                    index($2, "Models/silero-vad/") == 1 { print $2 }
            ' "$manifest" | LC_ALL=C sort) \
            <(find Models -type f -print | LC_ALL=C sort)
    })" || return 1
    [[ -z "$inventory_diff" ]] || {
        echo "error: model inventory does not exactly match the pinned manifest:" >&2
        printf '%s\n' "$inventory_diff" >&2
        return 1
    }
}
