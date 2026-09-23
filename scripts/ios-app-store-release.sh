#!/usr/bin/env bash
# Creates and verifies an iPhone/iPad App Store archive and signed IPA.
#
# This script deliberately never uploads. After it succeeds, upload the printed
# .ipa with Transporter or App Store Connect tooling as a separate action.
# For a TestFlight candidate, run scripts/testflight-release.sh so the macOS and
# iOS/iPadOS builds are always produced as one paired release gate.
#
# Optional controls:
#   ALLOW_DIRTY=1                    allow an uncommitted source tree
#   ALLOW_PROVISIONING_UPDATES=1     let Xcode download/manage signing assets
#   IOS_ARCHIVE_ONLY=1               verify the signed archive, but do not export
#   IOS_APP_STORE_VERSION=1.0.0      override MARKETING_VERSION
#   IOS_APP_STORE_BUILD_NUMBER=1     override CURRENT_PROJECT_VERSION
#   IOS_APP_STORE_OUTPUT_DIR=/path   override the versioned output directory

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/model-release.sh"

APP_NAME="yaprflow-iOS"
SCHEME="yaprflow-iOS"
PROJECT="yaprflow.xcodeproj"
CONFIGURATION="Release"
MODEL_CHECKSUMS="$ROOT/scripts/model-checksums.sha256"
ACKNOWLEDGEMENTS_SOURCE="$ROOT/yaprflow/Acknowledgements.txt"
MODEL_NOTICE_SOURCE="$ROOT/scripts/model-NOTICE.txt"
MODEL_ORIGIN_NOTICE_SOURCE="$ROOT/NOTICE.txt"
PRIVACY_MANIFEST_SOURCE="$ROOT/yaprflow-iOS/PrivacyInfo.xcprivacy"
SOURCE_INFO_PLIST="$ROOT/yaprflow-iOS/Info.plist"

EXPECTED_BUNDLE_ID="com.tmoreton.yaprflow.ios"
EXPECTED_TEAM_ID="GVXC5FQ2RP"
EXPECTED_MINIMUM_IOS="17.0"
EXPECTED_APPLICATION_ID="$EXPECTED_TEAM_ID.$EXPECTED_BUNDLE_ID"
EXPECTED_MICROPHONE_PURPOSE="Yaprflow uses the microphone for on-device dictation and in-person meeting transcripts. Audio never leaves your device."

usage() {
    sed -n '2,15p' "$0"
}

fail() {
    echo "error: $*" >&2
    exit 1
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unexpected argument: $1 (configuration is supplied with environment variables)"
            ;;
    esac
fi

for boolean_name in ALLOW_DIRTY ALLOW_PROVISIONING_UPDATES IOS_ARCHIVE_ONLY; do
    case "${!boolean_name:-0}" in
        0|1) ;;
        *) fail "$boolean_name must be 0 or 1" ;;
    esac
done

if [[ "${ALLOW_DIRTY:-0}" != "1" ]] \
   && [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "error: the working tree is not clean; commit or stash release changes first" >&2
    echo "       (set ALLOW_DIRTY=1 only for a deliberate local test)" >&2
    git status --short >&2
    exit 1
fi

for command_name in \
    awk basename cmp codesign comm date diff dirname find git grep head lipo \
    mkdir mktemp nm plutil security sed shasum sort swift tr unzip xcodebuild xcrun; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is unavailable"
"$ROOT/scripts/verify-app-icon.sh"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-ios-app-store-verify.XXXXXX")"
cleanup_temp() {
    if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
        find "$TEMP_ROOT" -depth -delete
    fi
}
trap cleanup_temp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

plist_value() {
    local plist_path="$1"
    local key_path="$2"
    /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null
}

plist_raw() {
    local plist_path="$1"
    local key_path="$2"
    plutil -extract "$key_path" raw -o - "$plist_path" 2>/dev/null
}

require_plist_value() {
    local plist_path="$1"
    local key_path="$2"
    local expected_value="$3"
    local actual_value
    actual_value="$(plist_value "$plist_path" "$key_path" || true)"
    [[ "$actual_value" == "$expected_value" ]] \
        || fail "$key_path must be $expected_value in $plist_path (found ${actual_value:-missing})"
}

require_nonempty_plist_value() {
    local plist_path="$1"
    local key_path="$2"
    local actual_value
    actual_value="$(plist_value "$plist_path" "$key_path" || true)"
    [[ -n "$actual_value" ]] || fail "$key_path is missing or empty in $plist_path"
}

require_absent_plist_key() {
    local plist_path="$1"
    local key_path="$2"
    if plist_value "$plist_path" "$key_path" >/dev/null 2>&1; then
        fail "$key_path must not be present in $plist_path"
    fi
}

require_exact_plist_array() {
    local plist_path="$1"
    local key_path="$2"
    shift 2
    local expected_value actual_value index=0
    for expected_value in "$@"; do
        actual_value="$(plist_value "$plist_path" "$key_path:$index" || true)"
        [[ "$actual_value" == "$expected_value" ]] \
            || fail "$key_path:$index must be $expected_value in $plist_path (found ${actual_value:-missing})"
        index=$((index + 1))
    done
    if plist_value "$plist_path" "$key_path:$index" >/dev/null 2>&1; then
        fail "$key_path contains unexpected entries in $plist_path"
    fi
}

require_exact_arm64() {
    local binary_path="$1"
    local architectures
    [[ -f "$binary_path" ]] || fail "missing native binary: $binary_path"
    architectures="$(lipo -archs "$binary_path" 2>/dev/null || true)"
    [[ "$architectures" == "arm64" ]] \
        || fail "$binary_path must contain exactly arm64 (found ${architectures:-none})"
}

require_ios_device_macho() {
    local binary_path="$1"
    local build_version
    build_version="$(xcrun vtool -show-build "$binary_path" 2>/dev/null || true)"
    grep -Eq '^[[:space:]]*platform IOS[[:space:]]*$' <<<"$build_version" \
        || fail "$binary_path is not built for the iOS device platform"
}

require_exact_simulator_architectures() {
    local binary_path="$1"
    local actual_architectures expected_architectures
    [[ -f "$binary_path" ]] || fail "missing simulator native binary: $binary_path"
    actual_architectures="$(
        lipo -archs "$binary_path" 2>/dev/null \
            | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u
    )"
    expected_architectures="$(printf '%s\n' arm64 x86_64 | LC_ALL=C sort)"
    [[ "$actual_architectures" == "$expected_architectures" ]] \
        || fail "$binary_path must contain arm64 and x86_64 simulator slices"
}

validate_source_plists() {
    plutil -lint "$SOURCE_INFO_PLIST" >/dev/null \
        || fail "the source iOS Info.plist is missing or invalid"
    require_plist_value "$SOURCE_INFO_PLIST" CFBundleIdentifier '$(PRODUCT_BUNDLE_IDENTIFIER)'
    require_plist_value "$SOURCE_INFO_PLIST" CFBundleShortVersionString '$(MARKETING_VERSION)'
    require_plist_value "$SOURCE_INFO_PLIST" CFBundleVersion '$(CURRENT_PROJECT_VERSION)'
    require_plist_value "$SOURCE_INFO_PLIST" NSMicrophoneUsageDescription "$EXPECTED_MICROPHONE_PURPOSE"
    require_plist_value "$SOURCE_INFO_PLIST" ITSAppUsesNonExemptEncryption "false"
    require_exact_plist_array "$SOURCE_INFO_PLIST" UIBackgroundModes audio
    require_exact_plist_array "$SOURCE_INFO_PLIST" UIRequiredDeviceCapabilities arm64 microphone
    require_absent_plist_key "$SOURCE_INFO_PLIST" CFBundleURLTypes
    require_absent_plist_key "$SOURCE_INFO_PLIST" NSSpeechRecognitionUsageDescription

    plutil -lint "$PRIVACY_MANIFEST_SOURCE" >/dev/null \
        || fail "the source iOS privacy manifest is missing or invalid"
    require_plist_value "$PRIVACY_MANIFEST_SOURCE" NSPrivacyTracking "false"
    require_absent_plist_key "$PRIVACY_MANIFEST_SOURCE" NSPrivacyTrackingDomains:0
    require_absent_plist_key "$PRIVACY_MANIFEST_SOURCE" NSPrivacyCollectedDataTypes:0
}

verify_app_payload() {
    local app_path="$1"
    local info_plist executable_name executable_path bundled_link
    info_plist="$app_path/Info.plist"

    [[ -f "$info_plist" ]] || fail "$app_path is missing Info.plist"
    [[ -z "$(find "$app_path" ! -type d ! -type f ! -type l -print -quit)" ]] \
        || fail "the app contains an unsupported special file"
    while IFS= read -r bundled_link; do
        [[ -e "$bundled_link" ]] \
            || fail "the app contains a broken symbolic link: ${bundled_link#"$app_path/"}"
    done < <(find "$app_path" -type l -print)

    require_plist_value "$info_plist" CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
    require_plist_value "$info_plist" CFBundleShortVersionString "$VERSION"
    require_plist_value "$info_plist" CFBundleVersion "$BUILD_NUMBER"
    require_plist_value "$info_plist" CFBundlePackageType APPL
    require_plist_value "$info_plist" CFBundleDisplayName Yaprflow
    require_plist_value "$info_plist" LSRequiresIPhoneOS true
    require_plist_value "$info_plist" MinimumOSVersion "$EXPECTED_MINIMUM_IOS"
    require_plist_value "$info_plist" ITSAppUsesNonExemptEncryption false
    require_plist_value "$info_plist" NSMicrophoneUsageDescription "$EXPECTED_MICROPHONE_PURPOSE"
    require_exact_plist_array "$info_plist" CFBundleSupportedPlatforms iPhoneOS
    require_exact_plist_array "$info_plist" UIDeviceFamily 1 2
    require_exact_plist_array "$info_plist" UIRequiredDeviceCapabilities arm64 microphone
    require_exact_plist_array "$info_plist" UIBackgroundModes audio
    require_plist_value "$info_plist" CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName AppIcon
    require_plist_value "$info_plist" CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName AppIcon
    require_absent_plist_key "$info_plist" CFBundleURLTypes
    require_absent_plist_key "$info_plist" NSSpeechRecognitionUsageDescription

    [[ -s "$app_path/Assets.car" ]] || fail "the app is missing its compiled asset catalog"
    [[ -s "$app_path/AppIcon60x60@2x.png" ]] || fail "the app is missing its iPhone App Store icon"
    [[ -s "$app_path/AppIcon76x76@2x~ipad.png" ]] || fail "the app is missing its iPad App Store icon"
    [[ ! -e "$app_path/__preview.dylib" && ! -e "$app_path/$APP_NAME.debug.dylib" ]] \
        || fail "the Release app contains a preview/debug dynamic library"

    [[ -s "$ACKNOWLEDGEMENTS_SOURCE" ]] \
        || fail "the source acknowledgements are missing or empty"
    cmp -s "$ACKNOWLEDGEMENTS_SOURCE" "$app_path/Acknowledgements.txt" \
        || fail "bundled Acknowledgements.txt does not match the reviewed source"
    [[ -s "$MODEL_NOTICE_SOURCE" ]] || fail "the source model notice is missing or empty"
    cmp -s "$MODEL_NOTICE_SOURCE" "$app_path/model-NOTICE.txt" \
        || fail "bundled model-NOTICE.txt does not match the reviewed source"
    [[ -s "$MODEL_ORIGIN_NOTICE_SOURCE" ]] \
        || fail "the retained model-origin notice is missing or empty"
    cmp -s "$MODEL_ORIGIN_NOTICE_SOURCE" "$app_path/NOTICE.txt" \
        || fail "bundled NOTICE.txt does not match the retained model-origin notice"
    [[ -f "$app_path/PrivacyInfo.xcprivacy" ]] \
        || fail "the app is missing PrivacyInfo.xcprivacy"
    plutil -lint "$app_path/PrivacyInfo.xcprivacy" >/dev/null \
        || fail "the bundled privacy manifest is invalid"
    cmp -s \
        <(plutil -convert xml1 -o - "$PRIVACY_MANIFEST_SOURCE") \
        <(plutil -convert xml1 -o - "$app_path/PrivacyInfo.xcprivacy") \
        || fail "bundled PrivacyInfo.xcprivacy does not match the reviewed source"

    yaprflow_verify_model_inventory \
        "$app_path" "$MODEL_CHECKSUMS" "$YAPRFLOW_ASR_MODEL_DIR" \
        || fail "the bundled model inventory failed verification"
    executable_name="$(plist_value "$info_plist" CFBundleExecutable || true)"
    [[ -n "$executable_name" ]] || fail "CFBundleExecutable is missing"
    executable_path="$app_path/$executable_name"
    require_exact_arm64 "$executable_path"
    require_ios_device_macho "$executable_path"
    if nm -gU "$executable_path" 2>/dev/null \
        | grep -Ei '(^|_)espeak(_|$)|espeak-ng|piper[_-]?phonemize' >/dev/null; then
        fail "the app executable contains excluded optional TTS symbols"
    fi
}

extract_and_verify_entitlements() {
    local app_path="$1"
    local label="$2"
    local entitlements_plist actual_keys allowed_keys unexpected_keys
    entitlements_plist="$TEMP_ROOT/$label-entitlements.plist"

    codesign -d --entitlements :- "$app_path" >"$entitlements_plist" 2>/dev/null \
        || fail "could not extract $label app entitlements"
    plutil -lint "$entitlements_plist" >/dev/null \
        || fail "$label app entitlements are not a valid plist"
    require_plist_value "$entitlements_plist" application-identifier "$EXPECTED_APPLICATION_ID"
    require_plist_value \
        "$entitlements_plist" com.apple.developer.team-identifier "$EXPECTED_TEAM_ID"
    if [[ "$label" == "export" ]]; then
        [[ "$(plist_value "$entitlements_plist" get-task-allow || true)" != "true" ]] \
            || fail "the exported App Store app unexpectedly allows debugger attachment"
    fi

    actual_keys="$(
        /usr/libexec/PlistBuddy -c Print "$entitlements_plist" \
            | awk '
                /^[[:space:]]+[^[:space:]].*[[:space:]]=[[:space:]]/ {
                    key = $0
                    sub(/^[[:space:]]+/, "", key)
                    sub(/[[:space:]]+=[[:space:]].*$/, "", key)
                    print key
                }
            ' | LC_ALL=C sort -u
    )"
    allowed_keys="$(
        printf '%s\n' \
            application-identifier \
            beta-reports-active \
            com.apple.developer.default-data-protection \
            com.apple.developer.team-identifier \
            get-task-allow \
            keychain-access-groups \
            | LC_ALL=C sort -u
    )"
    unexpected_keys="$(
        comm -23 \
            <(printf '%s\n' "$actual_keys") \
            <(printf '%s\n' "$allowed_keys")
    )"
    [[ -z "$unexpected_keys" ]] \
        || fail "$label app contains unreviewed entitlements: ${unexpected_keys//$'\n'/, }"
}

verify_signed_app() {
    local app_path="$1"
    local signature_kind="$2"
    local signing_details embedded_team framework_path

    codesign --verify --deep --strict --verbose=2 "$app_path" \
        || fail "$signature_kind app signature is invalid"
    signing_details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
    embedded_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signing_details" | head -n1)"
    [[ "$embedded_team" == "$EXPECTED_TEAM_ID" ]] \
        || fail "$signature_kind app signature team is ${embedded_team:-missing}, expected $EXPECTED_TEAM_ID"
    grep -q "^Identifier=$EXPECTED_BUNDLE_ID$" <<<"$signing_details" \
        || fail "$signature_kind code signature identifier is not $EXPECTED_BUNDLE_ID"
    case "$signature_kind" in
        archive)
            grep -Eq '^Authority=(Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution):' \
                <<<"$signing_details" \
                || fail "the archive does not use an Apple iOS signing identity"
            ;;
        export)
            grep -Eq '^Authority=(Apple Distribution|iPhone Distribution):' <<<"$signing_details" \
                || fail "the exported app does not use an Apple Distribution identity"
            ;;
        *) fail "internal error: unsupported signature kind $signature_kind" ;;
    esac

    for framework_path in "$app_path/Frameworks"/*.framework; do
        codesign --verify --strict --verbose=2 "$framework_path" \
            || fail "invalid nested framework signature: $framework_path"
    done
    extract_and_verify_entitlements "$app_path" "$signature_kind"
}

verify_provisioning_profile() {
    local app_path="$1"
    local profile_kind="$2"
    local embedded_profile profile_plist expiration expiration_epoch current_epoch profile_name
    embedded_profile="$app_path/embedded.mobileprovision"
    profile_plist="$TEMP_ROOT/$profile_kind-profile.plist"

    [[ -s "$embedded_profile" ]] \
        || fail "$profile_kind app has no embedded provisioning profile"
    security cms -D -i "$embedded_profile" >"$profile_plist" 2>/dev/null \
        || fail "$profile_kind provisioning profile cannot be decoded"
    plutil -lint "$profile_plist" >/dev/null \
        || fail "$profile_kind provisioning profile is invalid"
    require_plist_value "$profile_plist" TeamIdentifier:0 "$EXPECTED_TEAM_ID"
    require_plist_value "$profile_plist" Platform:0 iOS
    require_plist_value \
        "$profile_plist" Entitlements:application-identifier "$EXPECTED_APPLICATION_ID"
    require_plist_value \
        "$profile_plist" Entitlements:com.apple.developer.team-identifier "$EXPECTED_TEAM_ID"

    expiration="$(plist_raw "$profile_plist" ExpirationDate || true)"
    [[ -n "$expiration" ]] || fail "$profile_kind provisioning profile has no expiration date"
    expiration_epoch="$(
        date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null || true
    )"
    [[ -n "$expiration_epoch" ]] \
        || fail "could not parse provisioning profile expiration: $expiration"
    current_epoch="$(date '+%s')"
    [[ "$expiration_epoch" -gt "$current_epoch" ]] \
        || fail "$profile_kind provisioning profile expired at $expiration"

    if [[ "$profile_kind" == "export" ]]; then
        require_absent_plist_key "$profile_plist" ProvisionedDevices
        require_absent_plist_key "$profile_plist" ProvisionsAllDevices
        require_plist_value "$profile_plist" Entitlements:get-task-allow false
        require_plist_value "$profile_plist" Entitlements:beta-reports-active true
    fi

    profile_name="$(plist_value "$profile_plist" Name || true)"
    echo "==> Verified $profile_kind provisioning profile: ${profile_name:-unnamed} (expires $expiration)"
}

verify_archive_metadata() {
    local archive_path="$1"
    local archive_info="$archive_path/Info.plist"
    plutil -lint "$archive_info" >/dev/null || fail "the archive Info.plist is invalid"
    require_plist_value "$archive_info" ArchiveVersion 2
    require_plist_value "$archive_info" SchemeName "$SCHEME"
    require_plist_value \
        "$archive_info" ApplicationProperties:ApplicationPath "Applications/$APP_NAME.app"
    require_plist_value \
        "$archive_info" ApplicationProperties:CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
    require_plist_value \
        "$archive_info" ApplicationProperties:CFBundleShortVersionString "$VERSION"
    require_plist_value \
        "$archive_info" ApplicationProperties:CFBundleVersion "$BUILD_NUMBER"
    require_plist_value "$archive_info" ApplicationProperties:Team "$EXPECTED_TEAM_ID"
    require_nonempty_plist_value "$archive_info" ApplicationProperties:SigningIdentity
}

validate_ipa_entry() {
    local entry="$1"
    case "$entry" in
        ""|/*|../*|*/../*|*/..|./*|*/./*|*\\*)
            fail "the IPA contains an unsafe path: $entry"
            ;;
    esac
}

verify_ipa() {
    local ipa_path="$1"
    local extraction_root payload_root app_count exported_app nested_bundle entry
    [[ -s "$ipa_path" ]] || fail "the exported IPA is missing or empty"
    unzip -tq "$ipa_path" >/dev/null || fail "the exported IPA is not a valid ZIP archive"
    while IFS= read -r entry; do
        validate_ipa_entry "$entry"
    done < <(unzip -Z1 "$ipa_path")

    extraction_root="$TEMP_ROOT/ipa"
    mkdir "$extraction_root"
    unzip -q "$ipa_path" -d "$extraction_root"
    payload_root="$extraction_root/Payload"
    [[ -d "$payload_root" ]] || fail "the IPA does not contain Payload/"
    app_count="$(
        find "$payload_root" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print \
            | awk 'END { print NR + 0 }'
    )"
    [[ "$app_count" == "1" ]] \
        || fail "the IPA must contain exactly one top-level app (found $app_count)"
    exported_app="$(
        find "$payload_root" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print \
            | head -n1
    )"
    nested_bundle="$(
        find "$exported_app" -mindepth 1 \
            \( -type d -name '*.app' -o -type d -name '*.appex' \) -print -quit
    )"
    [[ -z "$nested_bundle" ]] \
        || fail "the IPA contains an unexpected nested app or extension: $nested_bundle"

    verify_app_payload "$exported_app"
    verify_signed_app "$exported_app" export
    verify_provisioning_profile "$exported_app" export
}

validate_source_plists
yaprflow_validate_model_checksum_manifest "$MODEL_CHECKSUMS" \
    || fail "the model checksum manifest is invalid"

if ! BUILD_SETTINGS="$(
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -showBuildSettings 2>/dev/null
)"; then
    fail "could not read Xcode build settings for $SCHEME"
fi

project_setting() {
    local setting_name="$1"
    awk -F ' = ' -v wanted="$setting_name" '
        {
            name = $1
            sub(/^[[:space:]]+/, "", name)
            sub(/[[:space:]]+$/, "", name)
            if (name == wanted) {
                print $2
                exit
            }
        }
    ' <<<"$BUILD_SETTINGS"
}

PROJECT_VERSION="$(project_setting MARKETING_VERSION)"
PROJECT_BUILD_NUMBER="$(project_setting CURRENT_PROJECT_VERSION)"
VERSION="${IOS_APP_STORE_VERSION:-$PROJECT_VERSION}"
BUILD_NUMBER="${IOS_APP_STORE_BUILD_NUMBER:-$PROJECT_BUILD_NUMBER}"

[[ -n "$PROJECT_VERSION" && -n "$PROJECT_BUILD_NUMBER" ]] \
    || fail "MARKETING_VERSION or CURRENT_PROJECT_VERSION is missing"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]] \
    || fail "IOS_APP_STORE_VERSION must contain three numeric components (for example, 1.0.0)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*([.][0-9]+){0,2}$ ]] \
    || fail "IOS_APP_STORE_BUILD_NUMBER must contain one to three numeric components"

[[ "$(project_setting PRODUCT_BUNDLE_IDENTIFIER)" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "the iOS target bundle identifier is not $EXPECTED_BUNDLE_ID"
[[ "$(project_setting DEVELOPMENT_TEAM)" == "$EXPECTED_TEAM_ID" ]] \
    || fail "the iOS target development team is not $EXPECTED_TEAM_ID"
[[ "$(project_setting IPHONEOS_DEPLOYMENT_TARGET)" == "$EXPECTED_MINIMUM_IOS" ]] \
    || fail "the iOS target minimum version is not $EXPECTED_MINIMUM_IOS"
[[ "$(project_setting PLATFORM_NAME)" == "iphoneos" ]] \
    || fail "the selected build destination is not the iOS device platform"
[[ "$(project_setting ARCHS)" == "arm64" ]] \
    || fail "the generic iOS Release target must build exactly arm64"
[[ "$(project_setting CODE_SIGN_STYLE)" == "Automatic" ]] \
    || fail "the iOS target must use automatic code signing"
[[ "$(project_setting CODE_SIGNING_ALLOWED)" == "YES" ]] \
    || fail "iOS device code signing is not enabled"
[[ "$(project_setting GENERATE_INFOPLIST_FILE)" == "NO" ]] \
    || fail "the iOS target must use its reviewed source Info.plist"
[[ "$(project_setting INFOPLIST_FILE)" == "yaprflow-iOS/Info.plist" ]] \
    || fail "the iOS target does not use yaprflow-iOS/Info.plist"
[[ "$(project_setting SUPPORTS_MACCATALYST)" == "NO" ]] \
    || fail "the iOS release unexpectedly enables Mac Catalyst"
[[ "$(project_setting SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD)" == "NO" ]] \
    || fail "the iOS release unexpectedly enables Designed for iPhone/iPad on Mac"
[[ "$(project_setting TARGETED_DEVICE_FAMILY)" == "1,2" ]] \
    || fail "the iOS target must support iPhone and iPad"
[[ "$(project_setting DEAD_CODE_STRIPPING)" == "YES" ]] \
    || fail "the iOS Release target must enable dead-code stripping"
[[ "$(project_setting VALIDATE_PRODUCT)" == "YES" ]] \
    || fail "the iOS Release target must enable product validation"

SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -Eq '"(Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution):' \
    <<<"$SIGNING_IDENTITIES"; then
    fail "no valid Apple iOS signing identity is installed"
fi
if [[ "${IOS_ARCHIVE_ONLY:-0}" != "1" \
   && "${ALLOW_PROVISIONING_UPDATES:-0}" != "1" ]] \
   && ! grep -Eq '"(Apple Distribution|iPhone Distribution):' <<<"$SIGNING_IDENTITIES"; then
    cat >&2 <<EOF
error: no Apple Distribution identity is installed for IPA export. Install the
distribution certificate, set ALLOW_PROVISIONING_UPDATES=1 to let authenticated
Xcode manage signing, or set IOS_ARCHIVE_ONLY=1 to validate only the archive.
EOF
    exit 1
fi

DEFAULT_OUTPUT_DIR="$ROOT/build/ios-app-store/$VERSION-$BUILD_NUMBER"
OUTPUT_DIR="${IOS_APP_STORE_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
[[ ! -e "$OUTPUT_DIR" ]] \
    || fail "output directory already exists: $OUTPUT_DIR (move or remove it before retrying)"

echo "==> Running shared transcription-policy tests"
swift test

echo "==> Running iOS meeting-store persistence smoke test"
"$ROOT/scripts/ios-meeting-store-smoke.sh"

echo "==> Verifying the pinned source model inventory"
"$ROOT/scripts/fetch-models.sh"
yaprflow_verify_model_inventory "$ROOT" "$MODEL_CHECKSUMS" \
    || fail "the source model inventory failed verification"

mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir "$OUTPUT_DIR"
ARCHIVE_PATH="$OUTPUT_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$OUTPUT_DIR/export"
PROVISIONING_ARGS=()
if [[ "${ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
    PROVISIONING_ARGS+=(-allowProvisioningUpdates)
fi

echo "==> Archiving $APP_NAME $VERSION ($BUILD_NUMBER) for the iOS App Store"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    ${PROVISIONING_ARGS[@]+"${PROVISIONING_ARGS[@]}"} \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    archive

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[[ -d "$ARCHIVED_APP" ]] || fail "the archive does not contain $ARCHIVED_APP"
echo "==> Verifying signed iOS archive"
verify_archive_metadata "$ARCHIVE_PATH"
verify_app_payload "$ARCHIVED_APP"
verify_signed_app "$ARCHIVED_APP" archive
verify_provisioning_profile "$ARCHIVED_APP" archive

if [[ "${IOS_ARCHIVE_ONLY:-0}" == "1" ]]; then
    echo
    echo "==> Signed iOS archive verified successfully"
    echo "    Version: $VERSION ($BUILD_NUMBER)"
    echo "    Archive: $ARCHIVE_PATH"
    echo "    Export skipped because IOS_ARCHIVE_ONLY=1. Nothing was uploaded."
    exit 0
fi

EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"
cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>$EXPECTED_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
plutil -lint "$EXPORT_OPTIONS" >/dev/null || fail "generated export options are invalid"
require_plist_value "$EXPORT_OPTIONS" method app-store-connect
require_plist_value "$EXPORT_OPTIONS" destination export
require_plist_value "$EXPORT_OPTIONS" teamID "$EXPECTED_TEAM_ID"
require_plist_value "$EXPORT_OPTIONS" signingStyle automatic
require_plist_value "$EXPORT_OPTIONS" manageAppVersionAndBuildNumber false

echo "==> Exporting a signed App Store IPA (destination=export; never upload)"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    ${PROVISIONING_ARGS[@]+"${PROVISIONING_ARGS[@]}"}

IPA_COUNT="$(
    find "$EXPORT_DIR" -maxdepth 2 -type f -name '*.ipa' -print \
        | awk 'END { print NR + 0 }'
)"
[[ "$IPA_COUNT" == "1" ]] \
    || fail "App Store export must produce exactly one signed IPA (found $IPA_COUNT)"
IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -type f -name '*.ipa' -print | head -n1)"

echo "==> Verifying exported IPA, app, frameworks, and provisioning profile"
verify_ipa "$IPA_PATH"

echo
echo "==> iOS App Store release package verified successfully"
echo "    Version: $VERSION ($BUILD_NUMBER)"
echo "    IPA: $IPA_PATH"
echo "    SHA-256: $(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
echo "    This script did not upload the IPA."
