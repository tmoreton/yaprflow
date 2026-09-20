#!/usr/bin/env bash
# Verifies the shared modern app icon used by both macOS and iOS/iPadOS.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$ROOT/yaprflow/AppIcon.icon"
ICON_JSON="$ICON_DIR/icon.json"
EXPECTED_RED="extended-srgb:1.00000,0.29412,0.16863,1.00000"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ -s "$ICON_JSON" ]] || fail "missing Icon Composer document: $ICON_JSON"
plutil -convert xml1 -o /dev/null "$ICON_JSON" \
    || fail "invalid Icon Composer JSON"

fill="$(plutil -extract fill.solid raw -o - "$ICON_JSON" 2>/dev/null || true)"
[[ "$fill" == "$EXPECTED_RED" ]] \
    || fail "AppIcon background must be the full-bleed solid Yaprflow red"

platforms="$(plutil -extract supported-platforms.squares raw -o - "$ICON_JSON" 2>/dev/null || true)"
[[ "$platforms" == "shared" ]] \
    || fail "AppIcon must be shared by macOS and iOS/iPadOS"

layer_name="$(plutil -extract groups.0.layers.0.image-name raw -o - "$ICON_JSON" 2>/dev/null || true)"
[[ -n "$layer_name" && -s "$ICON_DIR/Assets/$layer_name" ]] \
    || fail "AppIcon waveform layer is missing"

shadow="$(plutil -extract groups.0.shadow.kind raw -o - "$ICON_JSON" 2>/dev/null || true)"
translucency="$(plutil -extract groups.0.translucency.enabled raw -o - "$ICON_JSON" 2>/dev/null || true)"
[[ "$shadow" == "none" && "$translucency" == "false" ]] \
    || fail "AppIcon waveform must remain flat, opaque, and shadow-free"

grep -Fq 'fill="#11110F"' "$ICON_DIR/Assets/$layer_name" \
    || fail "AppIcon waveform must use the reviewed near-black fill"

echo "Shared Icon Composer app icon verified: full-bleed solid red, flat waveform, macOS + iOS/iPadOS"
