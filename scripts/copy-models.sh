#!/usr/bin/env bash
# Verifies and stages the exact pinned model inventory for an Xcode app bundle.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/model-release.sh"
MODEL_CHECKSUMS="$ROOT/scripts/model-checksums.sha256"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || fail "usage: scripts/copy-models.sh /path/to/App.app[/Contents/Resources]/Models model-directory"
destination="$1"
model_dir="$2"
case "$model_dir" in
    "$YAPRFLOW_ASR_MODEL_DIR") ;;
    *) fail "unsupported model directory: $model_dir" ;;
esac
[[ "$destination" == /* ]] || fail "model destination must be an absolute path"
case "$destination" in
    /*.app/Models|/*.app/Contents/Resources/Models) ;;
    *) fail "refusing unsafe model destination: $destination" ;;
esac
[[ ! -L "$destination" ]] || fail "model destination must not be a symbolic link"

destination_parent="$(dirname "$destination")"
mkdir -p "$destination_parent"
[[ -d "$destination_parent" && ! -L "$destination_parent" ]] \
    || fail "model destination parent must be a real directory"

yaprflow_verify_model_inventory "$ROOT" "$MODEL_CHECKSUMS" || exit 1

stage_root="$(mktemp -d "$destination_parent/.yaprflow-models.XXXXXX")"
cleanup() {
    if [[ -d "$stage_root" ]]; then
        find "$stage_root" -depth -delete
    fi
}
trap cleanup EXIT
stage_models="$stage_root/Models"
mkdir "$stage_models"

for staged_model_dir in "$model_dir" silero-vad; do
    rsync -a \
        --exclude '.cache' \
        --exclude '.DS_Store' \
        "$ROOT/Models/$staged_model_dir" "$stage_models/"
done
yaprflow_verify_model_inventory "$stage_root" "$MODEL_CHECKSUMS" "$model_dir" || exit 1

if [[ -e "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] \
        || fail "existing model destination must be a real directory"
    find "$destination" -depth -delete
fi
mv "$stage_models" "$destination"

echo "Copied verified model inventory to $destination"
