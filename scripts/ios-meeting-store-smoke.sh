#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-ios-meeting-smoke.XXXXXX")"

cleanup() {
    if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
        find "$TEMP_ROOT" -depth -delete
    fi
}
trap cleanup EXIT

xcrun swiftc \
    -parse-as-library \
    "$ROOT/Shared/TranscriptionCore.swift" \
    "$ROOT/Shared/MeetingCore.swift" \
    "$ROOT/Shared/MeetingPersistence.swift" \
    "$ROOT/yaprflow-iOS/MobileMeetingStore.swift" \
    "$ROOT/Tools/MobileMeetingStoreSmoke.swift" \
    -o "$TEMP_ROOT/mobile-meeting-store-smoke"

"$TEMP_ROOT/mobile-meeting-store-smoke"
