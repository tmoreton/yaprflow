#!/usr/bin/env bash
# Builds and verifies both Yaprflow TestFlight candidates as one release gate.
#
# The underlying platform scripts intentionally do not upload. After this
# wrapper succeeds, upload both printed artifacts together with Transporter or
# App Store Connect tooling.
#
# Platform-specific version, build, signing, archive-only, and output controls
# are forwarded unchanged. See:
#   scripts/app-store-release.sh --help
#   scripts/ios-app-store-release.sh --help

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

case "${1:-}" in
    "") ;;
    -h|--help)
        sed -n '2,11p' "$0"
        exit 0
        ;;
    *)
        echo "error: unexpected argument: $1" >&2
        exit 1
        ;;
esac

echo "==> Building the macOS TestFlight candidate"
"$ROOT/scripts/app-store-release.sh"
mac_status=$?

echo
echo "==> Building the iOS/iPadOS TestFlight candidate"
"$ROOT/scripts/ios-app-store-release.sh"
ios_status=$?

echo
if [[ "$mac_status" -ne 0 || "$ios_status" -ne 0 ]]; then
    echo "error: paired TestFlight release failed" >&2
    echo "       macOS status: $mac_status" >&2
    echo "       iOS/iPadOS status: $ios_status" >&2
    exit 1
fi

echo "==> Both TestFlight candidates built and verified successfully"
echo "    Upload both platform artifacts together; neither was uploaded by this script."
