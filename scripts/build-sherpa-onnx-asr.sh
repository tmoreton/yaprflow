#!/usr/bin/env bash
# Builds the local sherpa-onnx Swift package's Apple frameworks from pinned
# source with the optional TTS dependency disabled.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/model-release.sh"
PACKAGE_ROOT="$ROOT/Vendor/SherpaOnnxASR"
ARTIFACTS="$PACKAGE_ROOT/Artifacts"
NATIVE_CHECKSUMS="$ROOT/scripts/native-asr-checksums.sha256"
SHERPA_TAG="v1.13.8"
SHERPA_REVISION="11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf"
ONNXRUNTIME_VERSION="1.28.2"
ONNXRUNTIME_IOS_SHA256="306b740d513a1af5c9f1c3a7d2ca98d8bf5491a558a45ef2b14cbed4fde64059"
ONNXRUNTIME_MACOS_SHA256="39f816cac19cb76e0f504b2d7c91fec3e889c25bf5b9b474297b19eb0bd69a31"

fail() {
    echo "error: $*" >&2
    exit 1
}

for command_name in \
    awk cmake cmp curl df diff du find git grep ln mkdir mv nm perl readlink \
    rsync shasum swift unzip xcodebuild; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done

available_kb="$(df -Pk "${TMPDIR:-/tmp}" | awk 'NR == 2 {print $4}')"
[[ "$available_kb" =~ ^[0-9]+$ ]] || fail "could not determine temporary disk space"
(( available_kb >= 5 * 1024 * 1024 )) \
    || fail "at least 5 GiB of temporary disk space is required"

yaprflow_verify_sherpa_wrapper "$ROOT" \
    || fail "the vendored sherpa-onnx Swift wrapper does not match the reviewed $SHERPA_TAG language-bridge patch"
echo "==> Verified sherpa-onnx wrapper based on $SHERPA_TAG ($YAPRFLOW_UPSTREAM_SHERPA_WRAPPER_SHA256) with the reviewed language-option bridge"

work_root="$(mktemp -d -t yaprflow-sherpa-asr.XXXXXX)"
cleanup() {
    [[ -d "$work_root" ]] && find "$work_root" -depth -delete
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source_root="$work_root/sherpa-onnx"
git clone --quiet --depth 1 --branch "$SHERPA_TAG" \
    https://github.com/k2-fsa/sherpa-onnx.git "$source_root"
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$SHERPA_REVISION" ]] \
    || fail "sherpa-onnx tag resolved to an unexpected revision"

echo "==> Building sherpa-onnx $SHERPA_TAG for iOS without TTS"
ios_ort_root="$source_root/build-ios-no-tts/ios-onnxruntime/$ONNXRUNTIME_VERSION"
mkdir -p "$ios_ort_root"
ios_ort_zip="$work_root/onnxruntime-ios.xcframework.zip"
curl -fL --retry 3 -o "$ios_ort_zip" \
    "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-ios-static-xcframework-${ONNXRUNTIME_VERSION}.xcframework.zip"
[[ "$(shasum -a 256 "$ios_ort_zip" | awk '{print $1}')" == "$ONNXRUNTIME_IOS_SHA256" ]] \
    || fail "the ONNX Runtime iOS archive checksum did not match"
unzip -q "$ios_ort_zip" -d "$ios_ort_root"
ln -s "$ONNXRUNTIME_VERSION/onnxruntime.xcframework" \
    "$source_root/build-ios-no-tts/ios-onnxruntime/onnxruntime.xcframework"
# Keep the iOS build to the same ASR surface as macOS. These flags are applied
# to all three upstream CMake invocations in the disposable checkout.
perl -0pi -e '
    s/-DSHERPA_ONNX_ENABLE_TTS=OFF \\\n/-DSHERPA_ONNX_ENABLE_TTS=OFF \\\n  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \\\n/g;
' "$source_root/build-ios-no-tts.sh"
(
    cd "$source_root"
    SHERPA_ONNX_ONNXRUNTIME_VERSION="$ONNXRUNTIME_VERSION" ./build-ios-no-tts.sh
)

echo "==> Building sherpa-onnx $SHERPA_TAG for macOS without TTS"
# The upstream macOS script builds TTS by default. Modify only the disposable,
# revision-verified checkout: disable TTS/diarization and omit the three TTS
# archives from its final static framework.
perl -0pi -e '
    s/cmake \\\n/cmake \\\n  -DSHERPA_ONNX_ENABLE_TTS=OFF \\\n  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \\\n/;
    s/  \.\/install\/lib\/libucd\.a \\\n//;
    s/  \.\/install\/lib\/libpiper_phonemize\.a \\\n//;
    s/  \.\/install\/lib\/libespeak-ng\.a \\\n//;
' "$source_root/build-macos.sh"
(
    cd "$source_root"
    ./build-macos.sh
)

ios_framework="$source_root/build-ios-no-tts/sherpa-onnx.xcframework"
mac_framework="$source_root/build-macos/sherpa-onnx.xcframework"
[[ -d "$ios_framework" && -d "$mac_framework" ]] \
    || fail "one or more native framework builds did not produce an XCFramework"

echo "==> Preparing pinned ONNX Runtime $ONNXRUNTIME_VERSION artifacts"
mac_ort_zip="$work_root/onnxruntime-macos.xcframework.zip"
mac_ort_root="$work_root/onnxruntime-macos"
curl -fL --retry 3 -o "$mac_ort_zip" \
    "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-macos-static-xcframework-${ONNXRUNTIME_VERSION}.xcframework.zip"
[[ "$(shasum -a 256 "$mac_ort_zip" | awk '{print $1}')" == "$ONNXRUNTIME_MACOS_SHA256" ]] \
    || fail "the ONNX Runtime macOS archive checksum did not match"
mkdir -p "$mac_ort_root"
unzip -q "$mac_ort_zip" -d "$mac_ort_root"

ios_ort_framework="$ios_ort_root/onnxruntime.xcframework"
mac_ort_framework="$mac_ort_root/onnxruntime.xcframework"
ios_ort_binary="$ios_ort_framework/ios-arm64/onnxruntime.framework/onnxruntime"
mac_ort_binary="$mac_ort_framework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime"
[[ -f "$ios_ort_binary" && -f "$mac_ort_binary" ]] \
    || fail "one or more ONNX Runtime archives were incomplete"

# The upstream macOS archive expands the versioned framework links as real
# duplicate files/directories. That layout is ambiguous to codesign and is not
# suitable for App Store distribution. Restore the canonical framework layout
# before SwiftPM/Xcode copy and sign it.
mac_ort_bundle="$mac_ort_framework/macos-arm64_x86_64/onnxruntime.framework"
mac_ort_version="$mac_ort_bundle/Versions/A"
mac_ort_current="$mac_ort_bundle/Versions/Current"
if [[ -d "$mac_ort_current" && ! -L "$mac_ort_current" ]]; then
    find "$mac_ort_current" -depth -delete
    ln -s A "$mac_ort_current"
fi
[[ -L "$mac_ort_current" && "$(readlink "$mac_ort_current")" == "A" \
   && -f "$mac_ort_current/onnxruntime" ]] \
    || fail "the normalized ONNX Runtime macOS framework has an invalid Current link"

for framework_component in onnxruntime Headers Resources; do
    root_component="$mac_ort_bundle/$framework_component"
    version_component="$mac_ort_version/$framework_component"
    [[ -e "$root_component" && -e "$version_component" ]] \
        || fail "the ONNX Runtime macOS framework is missing $framework_component"
    if [[ -d "$root_component" ]]; then
        diff -qr "$root_component" "$version_component" >/dev/null \
            || fail "the duplicate ONNX Runtime $framework_component directories differ"
    else
        cmp -s "$root_component" "$version_component" \
            || fail "the duplicate ONNX Runtime $framework_component files differ"
    fi
    find "$root_component" -depth -delete
    ln -s "Versions/Current/$framework_component" "$root_component"
done

root_modules="$mac_ort_bundle/Modules"
version_modules="$mac_ort_version/Modules"
[[ -d "$root_modules" && ! -e "$version_modules" ]] \
    || fail "the ONNX Runtime macOS framework has an unexpected Modules layout"
mv "$root_modules" "$version_modules"
ln -s Versions/Current/Modules "$root_modules"

for framework_component in onnxruntime Headers Modules Resources; do
    [[ -L "$mac_ort_bundle/$framework_component" \
       && -e "$mac_ort_bundle/$framework_component" ]] \
        || fail "the normalized ONNX Runtime macOS framework has an invalid $framework_component link"
done

for native_binary in \
    "$ios_framework/ios-arm64/SherpaOnnxC.framework/SherpaOnnxC" \
    "$mac_framework/macos-arm64_x86_64/SherpaOnnxC.framework/SherpaOnnxC"; do
    [[ -f "$native_binary" ]] || fail "missing native framework binary: $native_binary"
    if nm -gU "$native_binary" 2>/dev/null \
        | grep -Eiq '(^|_)espeak(_|$)|espeak-ng|piper[_-]?phonemize'; then
        fail "TTS symbols were found in $native_binary"
    fi
done

mkdir -p "$ARTIFACTS/SherpaOnnxIOS.xcframework"
mkdir -p "$ARTIFACTS/SherpaOnnxMacOS.xcframework"
mkdir -p "$ARTIFACTS/OnnxRuntimeIOS.xcframework"
mkdir -p "$ARTIFACTS/OnnxRuntimeMacOS.xcframework"
rsync -a --delete "$ios_framework/" "$ARTIFACTS/SherpaOnnxIOS.xcframework/"
rsync -a --delete "$mac_framework/" "$ARTIFACTS/SherpaOnnxMacOS.xcframework/"
rsync -a --delete "$ios_ort_framework/" "$ARTIFACTS/OnnxRuntimeIOS.xcframework/"
rsync -a --delete "$mac_ort_framework/" "$ARTIFACTS/OnnxRuntimeMacOS.xcframework/"

echo "==> Verifying reviewed native artifact provenance"
yaprflow_verify_native_asr_artifacts "$ROOT" "$NATIVE_CHECKSUMS" \
    || fail "native outputs differ from scripts/native-asr-checksums.sha256; review the toolchain/output before updating the manifest"

echo "==> ASR-only Apple frameworks are ready"
du -sh \
    "$ARTIFACTS/SherpaOnnxIOS.xcframework" \
    "$ARTIFACTS/SherpaOnnxMacOS.xcframework" \
    "$ARTIFACTS/OnnxRuntimeIOS.xcframework" \
    "$ARTIFACTS/OnnxRuntimeMacOS.xcframework"
