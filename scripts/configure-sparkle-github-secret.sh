#!/usr/bin/env bash
# Copies the existing Sparkle EdDSA private key from this Mac's login Keychain
# into the protected GitHub Actions environment used by the update workflow.

set -euo pipefail

cd "$(dirname "$0")/.."

REPOSITORY="${1:-tmoreton/yaprflow}"
ENVIRONMENT_NAME="sparkle-release"
KEY_ACCOUNT="com.tmoreton.yaprflow"
EXPECTED_PUBLIC_KEY="+pDUc2ivfnr9FJrMcu8LIS+S19ek19DfS3XT209PmKE="

if ! [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "error: repository must be in owner/name form" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "error: authenticate GitHub CLI first with: gh auth login -h github.com" >&2
    exit 1
fi

GENERATE_KEYS="build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "error: Sparkle generate_keys was not found; resolve the Xcode package first" >&2
    exit 1
fi

PUBLIC_KEY="$($GENERATE_KEYS --account "$KEY_ACCOUNT" -p)"
if [[ "$PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]]; then
    echo "error: the Keychain key does not match Yaprflow's embedded public key" >&2
    exit 1
fi

TEMP_DIRECTORY="$(mktemp -d -t yaprflow-sparkle-key)"
TEMP_KEY="$TEMP_DIRECTORY/private-key"
cleanup() {
    chmod 600 "$TEMP_KEY" 2>/dev/null || true
    rm -f "$TEMP_KEY"
    rmdir "$TEMP_DIRECTORY" 2>/dev/null || true
}
trap cleanup EXIT

"$GENERATE_KEYS" --account "$KEY_ACCOUNT" -x "$TEMP_KEY" >/dev/null
chmod 600 "$TEMP_KEY"
gh api --method PUT "repos/$REPOSITORY/environments/$ENVIRONMENT_NAME" >/dev/null
gh secret set SPARKLE_PRIVATE_KEY \
    --repo "$REPOSITORY" \
    --env "$ENVIRONMENT_NAME" \
    < "$TEMP_KEY"

echo "Configured SPARKLE_PRIVATE_KEY in GitHub environment: $ENVIRONMENT_NAME"
