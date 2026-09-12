#!/usr/bin/env bash
# Builds yaprflow.app, signs + notarizes + staples it, and packages it into a
# local styled DMG. It can optionally tag and publish a source-only GitHub
# release; commercial production binaries are distributed through the App Store.
#
# Usage:
#   scripts/release.sh                                    # local DMG build (uses MARKETING_VERSION)
#   scripts/release.sh 5.0.1                              # local DMG build with explicit version
#   scripts/release.sh 5.0.0 --publish-source             # validate build + source-only release
#   scripts/release.sh 5.1.0 --publish-source --draft
#   scripts/release.sh 5.1.0 --publish-source --prerelease --notes "Release notes"
#   SKIP_NOTARIZE=1 scripts/release.sh                    # unsigned local test build
#
# Notarization credentials: by default this uses the `notary-yaprflow` keychain
# profile (created via `xcrun notarytool store-credentials`). Override with
# NOTARY_PROFILE=<name>, or with APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD.

set -euo pipefail

cd "$(dirname "$0")/.."

# ---- Args --------------------------------------------------------------------

VERSION=""
PUBLISH_SOURCE=false
NOTES=""
EXTRA_GH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish-source)
            PUBLISH_SOURCE=true
            shift
            ;;
        --publish)
            echo "error: --publish was retired because it uploaded production DMGs publicly." >&2
            echo "       Use --publish-source for a source-only GitHub release." >&2
            echo "       Use the App Store archive/export flow for commercial binaries." >&2
            exit 2
            ;;
        --draft)
            EXTRA_GH_ARGS+=(--draft)
            shift
            ;;
        --prerelease)
            EXTRA_GH_ARGS+=(--prerelease)
            shift
            ;;
        --notes)
            if [[ $# -lt 2 ]]; then
                echo "error: --notes requires a value" >&2
                exit 1
            fi
            NOTES="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "error: unexpected positional argument: $1" >&2
                exit 1
            fi
            VERSION="$1"
            shift
            ;;
    esac
done

# ---- Config ------------------------------------------------------------------

APP_NAME="yaprflow"
SCHEME="yaprflow"
PROJECT="yaprflow.xcodeproj"
CONFIGURATION="Release"

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg-staging"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
MODEL_CHECKSUMS="$(pwd)/scripts/model-checksums.sha256"
NATIVE_ASR_CHECKSUMS="$(pwd)/scripts/native-asr-checksums.sha256"
ACKNOWLEDGEMENTS_SOURCE="$(pwd)/yaprflow/Acknowledgements.txt"
MODEL_NOTICE_SOURCE="$(pwd)/scripts/model-NOTICE.txt"
MODEL_ORIGIN_NOTICE_SOURCE="$(pwd)/NOTICE.txt"
MODEL_LICENSE_SOURCE="$(pwd)/LICENSES/OpenMDW-1.1.txt"
PRIVACY_MANIFEST_SOURCE="$(pwd)/yaprflow/PrivacyInfo.xcprivacy"
ONNXRUNTIME_NOTICES_SOURCE="$(pwd)/LICENSES/ONNXRuntime-ThirdPartyNotices-v1.28.2.txt"
SHERPA_NOTICES_SOURCE="$(pwd)/LICENSES/SherpaOnnx-ThirdParty-v1.13.8"
SHERPA_ARTIFACTS_ROOT="$(pwd)/Vendor/SherpaOnnxASR/Artifacts"
EXPECTED_BUNDLE_ID="com.tmoreton.yaprflow"
EXPECTED_TEAM_ID="GVXC5FQ2RP"

source "$(pwd)/scripts/lib/model-release.sh"

require_native_asr_artifacts() {
    if ! yaprflow_verify_native_asr_artifacts "$(pwd)" "$NATIVE_ASR_CHECKSUMS"; then
        echo "       Run scripts/build-sherpa-onnx-asr.sh, then retry the release." >&2
        exit 1
    fi
}

require_native_asr_framework_layout() {
    local mac_ort_bundle mac_ort_component
    mac_ort_bundle="$SHERPA_ARTIFACTS_ROOT/OnnxRuntimeMacOS.xcframework/macos-arm64_x86_64/onnxruntime.framework"

    [[ -L "$mac_ort_bundle/Versions/Current" \
       && "$(readlink "$mac_ort_bundle/Versions/Current")" == "A" \
       && -e "$mac_ort_bundle/Versions/Current" ]] || {
        echo "error: invalid ONNX Runtime framework link: Versions/Current" >&2
        return 1
    }
    for mac_ort_component in onnxruntime Headers Modules Resources; do
        if [[ ! -L "$mac_ort_bundle/$mac_ort_component" \
           || "$(readlink "$mac_ort_bundle/$mac_ort_component")" != "Versions/Current/$mac_ort_component" \
           || ! -e "$mac_ort_bundle/$mac_ort_component" ]]; then
            echo "error: invalid ONNX Runtime framework link: $mac_ort_component" >&2
            return 1
        fi
    done
}

load_release_env() {
    local env_file="$1"
    local line line_number=0 key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            echo "error: $env_file:$line_number must use a simple KEY=VALUE entry" >&2
            return 1
        fi

        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
            APPLE_ID|APPLE_PASSWORD|APPLE_APP_PASSWORD|APPLE_TEAM_ID|\
            DEVELOPER_ID_APPLICATION|NOTARY_PROFILE|NOTARIZE_MAX_POLLS|\
            NOTARIZE_APP_ID|NOTARIZE_DMG_ID|SKIP_NOTARIZE|USE_APP)
                ;;
            *)
                echo "error: $env_file:$line_number contains unsupported release setting: $key" >&2
                return 1
                ;;
        esac

        # Assign the right-hand side literally. Do not evaluate quotes, command
        # substitutions, variable references, or any other shell syntax.
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$env_file"
}

if [[ -f .env ]]; then
    load_release_env .env
fi

# A pre-built bundle must not turn off source provenance enforcement. The app
# itself is checked again by verify_bundled_app below.
require_native_asr_artifacts
require_native_asr_framework_layout

read_marketing_version() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^[[:space:]]*MARKETING_VERSION = /{print $2; exit}'
}

if [[ -z "$VERSION" ]]; then
    VERSION="$(read_marketing_version)"
fi
if [[ -z "$VERSION" ]]; then
    echo "error: could not determine version (pass it as the first argument)" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo "error: version must contain one to three dot-separated integers: $VERSION" >&2
    exit 1
fi

DMG_NAME="$APP_NAME-$VERSION"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
TEMP_DMG="$BUILD_DIR/$DMG_NAME.tmp.dmg"
APP_ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
TAG="v$VERSION"
MOUNT_DEVICE=""
CLEANUP_ACTIVE=false

cleanup_release_artifacts() {
    [[ "$CLEANUP_ACTIVE" == true ]] || return 0
    if [[ -n "$MOUNT_DEVICE" ]]; then
        hdiutil detach "$MOUNT_DEVICE" -quiet >/dev/null 2>&1 \
            || hdiutil detach "$MOUNT_DEVICE" -force >/dev/null 2>&1 \
            || true
    fi
    rm -f "$TEMP_DMG" "$APP_ZIP"
    rm -rf "$STAGING_DIR"
}
trap cleanup_release_artifacts EXIT

# ---- Decide whether to sign + notarize ---------------------------------------

NOTARIZE=true
NOTARY_AUTH=()

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> SKIP_NOTARIZE=1 set; building unsigned/unnotarized DMG for local testing"
    NOTARIZE=false
else
    # Default to the keychain profile used by the historical release workflow.
    NOTARY_PROFILE="${NOTARY_PROFILE:-notary-yaprflow}"

    if [[ -n "${NOTARY_PROFILE}" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD")
    elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
    else
        cat >&2 <<EOF
error: notarization credentials not set.
Either:
  1. Create the keychain profile (one-time):
       xcrun notarytool store-credentials --apple-id you@example.com \\
           --team-id GVXC5FQ2RP --password xxxx-xxxx-xxxx-xxxx notary-yaprflow
  2. OR create .env with APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
  3. OR run with SKIP_NOTARIZE=1 for an unnotarized local build
EOF
        exit 1
    fi
fi

CODESIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Tim Moreton (GVXC5FQ2RP)}"
NOTARIZE_MAX_POLLS="${NOTARIZE_MAX_POLLS:-90}"
if ! [[ "$NOTARIZE_MAX_POLLS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: NOTARIZE_MAX_POLLS must be a positive integer" >&2
    exit 1
fi

# ---- Notarization helpers ----------------------------------------------------
# `notarytool submit --wait` intermittently crashes with `Bus error: 10` while
# polling, even though the upload succeeded. We submit without --wait, capture
# the submission id, and poll `notarytool info` ourselves. Set NOTARIZE_APP_ID
# or NOTARIZE_DMG_ID to resume a previous run without re-uploading.

notarize_status() {
    xcrun notarytool info "$1" "${NOTARY_AUTH[@]}" 2>/dev/null \
        | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' \
        | head -n1
}

notarize_wait() {
    local sub_id="$1"
    local label="$2"
    local status poll_count=0
    while :; do
        sleep 20
        poll_count=$((poll_count + 1))
        status=$(notarize_status "$sub_id" || true)
        echo "    $label: ${status:-unknown} (id: $sub_id)"
        case "$status" in
            Accepted) return 0 ;;
            "In Progress"|"")
                if [[ "$poll_count" -ge "$NOTARIZE_MAX_POLLS" ]]; then
                    echo "error: $label notarization did not finish after $poll_count checks" >&2
                    return 1
                fi
                continue
                ;;
            *)
                echo "error: $label notarization finished with status: $status" >&2
                xcrun notarytool log "$sub_id" "${NOTARY_AUTH[@]}" >&2 || true
                return 1
                ;;
        esac
    done
}

notarize_submit_and_wait() {
    local file="$1"
    local label="$2"
    local submit_output sub_id
    if ! submit_output=$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" 2>&1); then
        echo "$submit_output" >&2
        return 1
    fi
    echo "$submit_output"
    sub_id=$(echo "$submit_output" | sed -n 's/^[[:space:]]*id:[[:space:]]*//p' | head -n1)
    if [[ -z "$sub_id" ]]; then
        echo "error: could not parse submission id from notarytool output" >&2
        return 1
    fi
    notarize_wait "$sub_id" "$label"
}

verify_bundled_app() {
    local app_path="$1"
    local resources_path="$app_path/Contents/Resources"
    local info_plist="$app_path/Contents/Info.plist"
    local embedded_version embedded_bundle_id
    local executable_name executable_path bundled_link

    if [[ ! -f "$MODEL_CHECKSUMS" || ! -f "$ACKNOWLEDGEMENTS_SOURCE" \
       || ! -f "$MODEL_NOTICE_SOURCE" || ! -f "$MODEL_ORIGIN_NOTICE_SOURCE" \
       || ! -f "$MODEL_LICENSE_SOURCE" \
       || ! -f "$PRIVACY_MANIFEST_SOURCE" || ! -f "$ONNXRUNTIME_NOTICES_SOURCE" \
       || ! -d "$SHERPA_NOTICES_SOURCE" ]]; then
        echo "error: release verification sources are missing" >&2
        return 1
    fi
    yaprflow_validate_model_checksum_manifest "$MODEL_CHECKSUMS" || return 1
    if [[ ! -f "$info_plist" || ! -d "$resources_path/Models" ]]; then
        echo "error: $app_path is missing its Info.plist or bundled Models directory" >&2
        return 1
    fi
    while IFS= read -r bundled_link; do
        if [[ ! -e "$bundled_link" ]]; then
            echo "error: app contains a broken symbolic link: ${bundled_link#"$app_path/"}" >&2
            return 1
        fi
    done < <(find "$app_path" -type l -print)

    embedded_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
    embedded_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
    if [[ "$embedded_version" != "$VERSION" ]]; then
        echo "error: requested version $VERSION does not match bundled version $embedded_version" >&2
        return 1
    fi
    if [[ "$embedded_bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
        echo "error: unexpected bundle id: $embedded_bundle_id" >&2
        return 1
    fi

    if ! cmp -s "$ACKNOWLEDGEMENTS_SOURCE" "$resources_path/Acknowledgements.txt"; then
        echo "error: bundled Acknowledgements.txt is missing or does not match the source notice" >&2
        return 1
    fi
    if ! cmp -s "$MODEL_NOTICE_SOURCE" "$resources_path/model-NOTICE.txt"; then
        echo "error: bundled model-NOTICE.txt is missing or does not match the source notice" >&2
        return 1
    fi
    if ! cmp -s "$MODEL_ORIGIN_NOTICE_SOURCE" "$resources_path/NOTICE.txt"; then
        echo "error: bundled NOTICE.txt is missing or does not match the retained model-origin notice" >&2
        return 1
    fi
    if ! cmp -s \
        "$MODEL_LICENSE_SOURCE" \
        "$resources_path/OpenMDW-1.1.txt"; then
        echo "error: bundled OpenMDW-1.1 license is missing or changed" >&2
        return 1
    fi
    if ! cmp -s \
        "$ONNXRUNTIME_NOTICES_SOURCE" \
        "$resources_path/ONNXRuntime-ThirdPartyNotices-v1.28.2.txt"; then
        echo "error: bundled ONNX Runtime notices are missing or do not match the source" >&2
        return 1
    fi
    if ! diff -qr \
        "$SHERPA_NOTICES_SOURCE" \
        "$resources_path/SherpaOnnx-ThirdParty-v1.13.8" >/dev/null; then
        echo "error: bundled sherpa-onnx dependency notices are missing or changed" >&2
        return 1
    fi
    if [[ ! -f "$resources_path/PrivacyInfo.xcprivacy" ]] \
       || ! plutil -lint "$PRIVACY_MANIFEST_SOURCE" >/dev/null \
       || ! plutil -lint "$resources_path/PrivacyInfo.xcprivacy" >/dev/null \
       || ! cmp -s \
            <(plutil -convert xml1 -o - "$PRIVACY_MANIFEST_SOURCE") \
            <(plutil -convert xml1 -o - "$resources_path/PrivacyInfo.xcprivacy"); then
        echo "error: bundled privacy manifest is missing or invalid" >&2
        return 1
    fi

    yaprflow_verify_model_inventory "$resources_path" "$MODEL_CHECKSUMS" || return 1

    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
    executable_path="$app_path/Contents/MacOS/$executable_name"
    if [[ ! -f "$executable_path" ]]; then
        echo "error: bundled app executable is missing" >&2
        return 1
    fi
    if nm -gU "$executable_path" 2>/dev/null \
        | grep -Ei '(^|_)espeak(_|$)|espeak-ng|piper[_-]?phonemize' >/dev/null; then
        echo "error: app executable contains prohibited optional TTS symbols" >&2
        return 1
    fi
    if nm -gU "$executable_path" 2>/dev/null \
        | grep -F '$s10FluidAudio' >/dev/null; then
        echo "error: app executable links the full FluidAudio package" >&2
        return 1
    fi

    echo "==> Verified app identity, privacy manifest, notices, and pinned models"
}

verify_distribution_signature() {
    local app_path="$1"
    local signing_details embedded_team embedded_entitlements sandbox_entitlement microphone_entitlement

    codesign --verify --deep --strict --verbose=2 "$app_path"
    signing_details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
    embedded_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signing_details" | head -n1)"

    if [[ "$embedded_team" != "$EXPECTED_TEAM_ID" ]]; then
        echo "error: expected signing team $EXPECTED_TEAM_ID, found ${embedded_team:-none}" >&2
        return 1
    fi
    if ! grep -q '^Authority=Developer ID Application:' <<<"$signing_details"; then
        echo "error: app is not signed with a Developer ID Application certificate" >&2
        return 1
    fi
    if ! grep -q '^CodeDirectory .*flags=.*runtime' <<<"$signing_details"; then
        echo "error: app signature does not enable the hardened runtime" >&2
        return 1
    fi

    embedded_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null)"
    sandbox_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' /dev/stdin <<<"$embedded_entitlements" 2>/dev/null || true)"
    microphone_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' /dev/stdin <<<"$embedded_entitlements" 2>/dev/null || true)"
    if [[ "$sandbox_entitlement" != "true" || "$microphone_entitlement" != "true" ]]; then
        echo "error: app signature is missing the sandbox or microphone entitlement" >&2
        return 1
    fi
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' \
        /dev/stdin <<<"$embedded_entitlements" >/dev/null 2>&1 \
       || /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' \
        /dev/stdin <<<"$embedded_entitlements" >/dev/null 2>&1; then
        echo "error: app signature unexpectedly allows outbound network access" >&2
        return 1
    fi
}

# ---- Pre-publish guards ------------------------------------------------------

if [[ "$PUBLISH_SOURCE" == true ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh (GitHub CLI) is not installed. brew install gh" >&2
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "error: gh is not authenticated. run: gh auth login" >&2
        exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: working tree has uncommitted changes — commit or stash before --publish-source" >&2
        git status --short >&2
        exit 1
    fi
fi

CLEANUP_ACTIVE=true

if [[ -n "${USE_APP:-}" ]]; then
    if [[ ! -d "$USE_APP" ]]; then
        echo "error: USE_APP=$USE_APP not found" >&2
        exit 1
    fi
    APP_PATH="$USE_APP"
    rm -rf "$STAGING_DIR" "$DMG_PATH" "$TEMP_DMG"
    mkdir -p "$BUILD_DIR"
    echo "==> Using pre-built .app: $APP_PATH (skipping build + .app notarization)"
else
    # ---- Verify model files -------------------------------------------------

    # Every archive is built from the exact pinned model inventory. The fetch
    # script downloads missing models, removes fetch metadata, checks every
    # file hash, and rejects unexpected files before Xcode copies Models/.
    echo "==> Verifying pinned model files"
    scripts/fetch-models.sh

    # ---- Build --------------------------------------------------------------

    echo "==> Building $APP_NAME $VERSION"
    rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$STAGING_DIR" "$DMG_PATH" "$TEMP_DMG" "$APP_ZIP"
    mkdir -p "$BUILD_DIR"

    echo "==> Archiving"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        MARKETING_VERSION="$VERSION" \
        archive

    # ---- Get a Developer-ID-signed .app -------------------------------------

    if [[ "$NOTARIZE" == true ]]; then
        echo "==> Exporting with developer-id signing"
        cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID:-GVXC5FQ2RP}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportPath "$EXPORT_DIR" \
            -exportOptionsPlist "$EXPORT_OPTIONS"
        APP_PATH="$EXPORT_DIR/$APP_NAME.app"
    else
        APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
    fi

    if [[ ! -d "$APP_PATH" ]]; then
        echo "error: $APP_PATH not found" >&2
        exit 1
    fi

    # ---- Notarize + staple the .app -----------------------------------------

    if [[ "$NOTARIZE" == true ]]; then
        if [[ -n "${NOTARIZE_APP_ID:-}" ]]; then
            echo "==> Resuming .app notarization: $NOTARIZE_APP_ID"
            notarize_wait "$NOTARIZE_APP_ID" ".app"
        else
            echo "==> Verifying .app signature"
            codesign --verify --deep --strict --verbose=2 "$APP_PATH"

            echo "==> Zipping .app for notarization"
            /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

            echo "==> Submitting .app to Apple notary service (this can take a few minutes)"
            notarize_submit_and_wait "$APP_ZIP" ".app"
            rm -f "$APP_ZIP"
        fi

        echo "==> Stapling .app"
        xcrun stapler staple "$APP_PATH"
        xcrun stapler validate "$APP_PATH"
    fi
fi

verify_bundled_app "$APP_PATH"
if [[ "$NOTARIZE" == true ]]; then
    verify_distribution_signature "$APP_PATH"
    if [[ -n "${USE_APP:-}" ]]; then
        xcrun stapler validate "$APP_PATH"
        spctl --assess --type execute --verbose=2 "$APP_PATH"
    fi
fi

# ---- Build DMG ---------------------------------------------------------------

echo "==> Staging DMG contents"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating writable DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    "$TEMP_DMG" >/dev/null

echo "==> Mounting and styling"
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
DEVICE=$(echo "$MOUNT_OUTPUT" | grep -E '^/dev/' | head -n1 | awk '{print $1}')
MOUNT_PATH=$(echo "$MOUNT_OUTPUT" | grep -E "/Volumes/$APP_NAME" | sed -E 's/.*(\/Volumes\/[^	]+)$/\1/')
if [[ -n "$DEVICE" ]]; then
    MOUNT_DEVICE="$DEVICE"
fi

if [[ -z "$DEVICE" || -z "$MOUNT_PATH" ]]; then
    echo "error: failed to mount $TEMP_DMG" >&2
    exit 1
fi

sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 740, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set position of item "$APP_NAME.app" of container window to {145, 200}
        set position of item "Applications" of container window to {395, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync

echo "==> Detaching"
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force
MOUNT_DEVICE=""

echo "==> Compressing"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

# ---- Sign + notarize + staple the DMG ---------------------------------------

if [[ "$NOTARIZE" == true ]]; then
    echo "==> Signing DMG"
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"

    if [[ -n "${NOTARIZE_DMG_ID:-}" ]]; then
        echo "==> Resuming DMG notarization: $NOTARIZE_DMG_ID"
        notarize_wait "$NOTARIZE_DMG_ID" "DMG"
    else
        echo "==> Submitting DMG to Apple notary service"
        notarize_submit_and_wait "$DMG_PATH" "DMG"
    fi

    echo "==> Stapling DMG"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    echo "==> Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
fi

echo
echo "==> Built: $DMG_PATH"
ls -lh "$DMG_PATH"

# ---- Publish source-only GitHub release -------------------------------------

if [[ "$PUBLISH_SOURCE" == true ]]; then
    echo
    HEAD_COMMIT="$(git rev-parse HEAD)"
    TAG_EXISTS_LOCALLY=false
    if git show-ref --verify --quiet "refs/tags/$TAG"; then
        TAG_EXISTS_LOCALLY=true
        TAG_COMMIT="$(git rev-list -n1 "$TAG")"
        if [[ "$TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
            echo "error: existing tag $TAG points to $TAG_COMMIT, not HEAD $HEAD_COMMIT" >&2
            exit 1
        fi
        echo "==> Tag $TAG already exists locally at HEAD — skipping create"
    fi

    REMOTE_TAGS="$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null)"
    TAG_EXISTS_REMOTELY=false
    if [[ -n "$REMOTE_TAGS" ]]; then
        TAG_EXISTS_REMOTELY=true
        REMOTE_TAG_COMMIT="$(awk -v peeled="refs/tags/$TAG^{}" '$2 == peeled {print $1; exit}' <<<"$REMOTE_TAGS")"
        if [[ -z "$REMOTE_TAG_COMMIT" ]]; then
            REMOTE_TAG_COMMIT="$(awk -v direct="refs/tags/$TAG" '$2 == direct {print $1; exit}' <<<"$REMOTE_TAGS")"
        fi
        if [[ "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
            echo "error: origin tag $TAG does not resolve to HEAD $HEAD_COMMIT" >&2
            exit 1
        fi
        echo "==> Tag $TAG already on origin at HEAD — skipping push"
    fi

    if [[ "$TAG_EXISTS_LOCALLY" == false ]]; then
        echo "==> Tagging $TAG"
        git tag -a "$TAG" -m "yaprflow $VERSION"
    fi
    if [[ "$TAG_EXISTS_REMOTELY" == false ]]; then
        git push origin "$TAG"
    fi

    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "==> Source release $TAG already exists — leaving immutable release unchanged"
    else
        echo "==> Creating source-only GitHub release"
        RELEASE_ARGS=("$TAG" --title "Yaprflow $VERSION source")
        if [[ -n "$NOTES" ]]; then
            RELEASE_ARGS+=(--notes "$NOTES")
        else
            RELEASE_ARGS+=(--generate-notes)
        fi
        if [[ ${#EXTRA_GH_ARGS[@]} -gt 0 ]]; then
            RELEASE_ARGS+=("${EXTRA_GH_ARGS[@]}")
        fi
        gh release create "${RELEASE_ARGS[@]}"
    fi

    echo
    echo "==> Published source-only release $TAG"
fi
