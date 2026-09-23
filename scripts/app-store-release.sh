#!/usr/bin/env bash
# Creates and verifies a Mac App Store archive and signed installer package.
#
# This script deliberately does not upload anything. After it succeeds, upload
# the printed .pkg with Transporter or App Store Connect tooling as a separate,
# intentional step.
# For a TestFlight candidate, run scripts/testflight-release.sh so the macOS and
# iOS/iPadOS builds are always produced as one paired release gate.
#
# Optional controls:
#   ALLOW_DIRTY=1                  allow an uncommitted source tree
#   ALLOW_PROVISIONING_UPDATES=1   let Xcode download/manage signing assets
#   APP_STORE_VERSION=5.0.0        override MARKETING_VERSION
#   APP_STORE_BUILD_NUMBER=3       override CURRENT_PROJECT_VERSION
#   APP_STORE_OUTPUT_DIR=/path     override the versioned output directory

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/model-release.sh"

APP_NAME="yaprflow"
SCHEME="yaprflow-AppStore"
PROJECT="yaprflow.xcodeproj"
CONFIGURATION="Release"
EXPORT_OPTIONS="$ROOT/AppStore/ExportOptions.plist"
MODEL_CHECKSUMS="$ROOT/scripts/model-checksums.sha256"
ACKNOWLEDGEMENTS_SOURCE="$ROOT/yaprflow/Acknowledgements.txt"
MODEL_NOTICE_SOURCE="$ROOT/scripts/model-NOTICE.txt"
MODEL_ORIGIN_NOTICE_SOURCE="$ROOT/NOTICE.txt"
PRIVACY_MANIFEST_SOURCE="$ROOT/yaprflow/PrivacyInfo.xcprivacy"

EXPECTED_BUNDLE_ID="com.tmoreton.yaprflow"
EXPECTED_TEAM_ID="GVXC5FQ2RP"
EXPECTED_CATEGORY="public.app-category.productivity"
EXPECTED_MINIMUM_MACOS="14.0"
EXPECTED_APPLICATION_ID="$EXPECTED_TEAM_ID.$EXPECTED_BUNDLE_ID"
EXPECTED_DISTRIBUTION="app-store"

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

case "${ALLOW_DIRTY:-0}" in
    0|1) ;;
    *) fail "ALLOW_DIRTY must be 0 or 1" ;;
esac
case "${ALLOW_PROVISIONING_UPDATES:-0}" in
    0|1) ;;
    *) fail "ALLOW_PROVISIONING_UPDATES must be 0 or 1" ;;
esac

if [[ "${ALLOW_DIRTY:-0}" != "1" ]] && [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "error: the working tree is not clean; commit or stash release changes first" >&2
    echo "       (set ALLOW_DIRTY=1 only for a deliberate local test)" >&2
    git status --short >&2
    exit 1
fi

for command_name in \
    awk cmp codesign comm date diff dirname find git grep head lipo mkdir mktemp nm \
    otool pkgutil plutil readlink security sed shasum sort tr xcodebuild; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is unavailable"

"$ROOT/scripts/verify-app-icon.sh"

if ! BUILD_SETTINGS="$(
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=macOS" \
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
VERSION="${APP_STORE_VERSION:-$PROJECT_VERSION}"
BUILD_NUMBER="${APP_STORE_BUILD_NUMBER:-$PROJECT_BUILD_NUMBER}"

[[ -n "$PROJECT_VERSION" && -n "$PROJECT_BUILD_NUMBER" ]] \
    || fail "MARKETING_VERSION or CURRENT_PROJECT_VERSION is missing"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]] \
    || fail "APP_STORE_VERSION must contain three numeric components (for example, 5.0.0)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*([.][0-9]+){0,2}$ ]] \
    || fail "APP_STORE_BUILD_NUMBER must contain one to three numeric components"

[[ "$(project_setting PRODUCT_BUNDLE_IDENTIFIER)" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "the Xcode target bundle identifier is not $EXPECTED_BUNDLE_ID"
[[ "$(project_setting DEVELOPMENT_TEAM)" == "$EXPECTED_TEAM_ID" ]] \
    || fail "the Xcode target development team is not $EXPECTED_TEAM_ID"
[[ "$(project_setting MACOSX_DEPLOYMENT_TARGET)" == "$EXPECTED_MINIMUM_MACOS" ]] \
    || fail "the Xcode target minimum macOS version is not $EXPECTED_MINIMUM_MACOS"
[[ "$(project_setting ENABLE_APP_SANDBOX)" == "YES" ]] \
    || fail "the Xcode target does not enable App Sandbox"
[[ "$(project_setting ENABLE_HARDENED_RUNTIME)" == "YES" ]] \
    || fail "the Xcode target does not enable the hardened runtime"
[[ "$(project_setting DEAD_CODE_STRIPPING)" == "YES" ]] \
    || fail "the Xcode Release target does not enable dead-code stripping"
[[ "$(project_setting VALIDATE_PRODUCT)" == "YES" ]] \
    || fail "the Xcode Release target does not enable product validation"
[[ "$(project_setting INFOPLIST_FILE)" == "yaprflow/Info-AppStore.plist" ]] \
    || fail "the App Store scheme is not using Info-AppStore.plist"
[[ "$(project_setting CODE_SIGN_ENTITLEMENTS)" == "yaprflow/yaprflow-AppStore.entitlements" ]] \
    || fail "the App Store scheme is not using its restricted entitlement file"
APP_STORE_CONDITIONS="$(project_setting SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
[[ " $APP_STORE_CONDITIONS " == *" APP_STORE_DISTRIBUTION "* ]] \
    || fail "the App Store scheme is missing APP_STORE_DISTRIBUTION"
[[ " $APP_STORE_CONDITIONS " != *" DIRECT_DISTRIBUTION "* ]] \
    || fail "the App Store scheme must not compile the direct updater path"

plist_raw() {
    local plist_path="$1"
    local key_path="$2"
    plutil -extract "$key_path" raw -o - "$plist_path" 2>/dev/null
}

validate_export_options() {
    [[ -f "$EXPORT_OPTIONS" ]] || fail "missing $EXPORT_OPTIONS"
    plutil -lint "$EXPORT_OPTIONS" >/dev/null \
        || fail "invalid export options plist: $EXPORT_OPTIONS"
    [[ "$(plist_raw "$EXPORT_OPTIONS" method)" == "app-store-connect" ]] \
        || fail "App Store export method must be app-store-connect"
    [[ "$(plist_raw "$EXPORT_OPTIONS" destination)" == "export" ]] \
        || fail "App Store export destination must be export (never upload)"
    [[ "$(plist_raw "$EXPORT_OPTIONS" teamID)" == "$EXPECTED_TEAM_ID" ]] \
        || fail "App Store export teamID must be $EXPECTED_TEAM_ID"
    [[ "$(plist_raw "$EXPORT_OPTIONS" signingStyle)" == "automatic" ]] \
        || fail "App Store export signingStyle must be automatic"
    [[ "$(plist_raw "$EXPORT_OPTIONS" manageAppVersionAndBuildNumber)" == "false" ]] \
        || fail "Xcode must not change the selected app version or build number"
}

validate_checksum_manifest() {
    yaprflow_validate_model_checksum_manifest "$MODEL_CHECKSUMS" || exit 1
}

verify_model_inventory() {
    local inventory_root="$1"
    yaprflow_verify_model_inventory "$inventory_root" "$MODEL_CHECKSUMS" || exit 1
}

plist_value() {
    local plist_path="$1"
    local key_name="$2"
    /usr/libexec/PlistBuddy -c "Print :$key_name" "$plist_path" 2>/dev/null
}

require_plist_value() {
    local plist_path="$1"
    local key_name="$2"
    local expected_value="$3"
    local actual_value
    actual_value="$(plist_value "$plist_path" "$key_name" || true)"
    [[ "$actual_value" == "$expected_value" ]] \
        || fail "$key_name must be $expected_value (found ${actual_value:-missing})"
}

verify_app_payload() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local resources_path="$app_path/Contents/Resources"
    local executable_name executable_path bundled_link

    [[ -f "$info_plist" ]] || fail "$app_path is missing Contents/Info.plist"
    require_plist_value "$info_plist" CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
    require_plist_value "$info_plist" CFBundleShortVersionString "$VERSION"
    require_plist_value "$info_plist" CFBundleVersion "$BUILD_NUMBER"
    require_plist_value "$info_plist" CFBundlePackageType "APPL"
    require_plist_value "$info_plist" LSApplicationCategoryType "$EXPECTED_CATEGORY"
    require_plist_value "$info_plist" LSMinimumSystemVersion "$EXPECTED_MINIMUM_MACOS"
    require_plist_value "$info_plist" LSUIElement "true"
    require_plist_value "$info_plist" ITSAppUsesNonExemptEncryption "false"
    require_plist_value "$info_plist" CFBundleIconFile "AppIcon"
    require_plist_value "$info_plist" CFBundleIconName "AppIcon"
    require_plist_value "$info_plist" YaprflowDistribution "$EXPECTED_DISTRIBUTION"

    for sparkle_key in \
        SUAllowsAutomaticUpdates \
        SUAutomaticallyUpdate \
        SUEnableAutomaticChecks \
        SUEnableInstallerLauncherService \
        SUEnableSystemProfiling \
        SUFeedURL \
        SUPublicEDKey \
        SUScheduledCheckInterval; do
        if plist_value "$info_plist" "$sparkle_key" >/dev/null 2>&1; then
            fail "the App Store app must not contain Sparkle setting $sparkle_key"
        fi
    done
    if find "$app_path/Contents" -iname '*sparkle*' -print -quit | grep -q .; then
        fail "the App Store app must not bundle Sparkle files"
    fi

    while IFS= read -r bundled_link; do
        [[ -e "$bundled_link" ]] \
            || fail "the app contains a broken symbolic link: ${bundled_link#"$app_path/"}"
    done < <(find "$app_path" -type l -print)

    [[ -s "$resources_path/AppIcon.icns" ]] \
        || fail "the built app is missing its non-empty AppIcon.icns"
    [[ -s "$ACKNOWLEDGEMENTS_SOURCE" ]] \
        || fail "the source acknowledgements file is missing or empty"
    cmp -s "$ACKNOWLEDGEMENTS_SOURCE" "$resources_path/Acknowledgements.txt" \
        || fail "bundled Acknowledgements.txt does not match the reviewed source notice"
    [[ -s "$MODEL_NOTICE_SOURCE" ]] \
        || fail "the source model notice is missing or empty"
    cmp -s "$MODEL_NOTICE_SOURCE" "$resources_path/model-NOTICE.txt" \
        || fail "bundled model-NOTICE.txt does not match the reviewed source notice"
    [[ -s "$MODEL_ORIGIN_NOTICE_SOURCE" ]] \
        || fail "the retained model-origin NOTICE.txt is missing or empty"
    cmp -s "$MODEL_ORIGIN_NOTICE_SOURCE" "$resources_path/NOTICE.txt" \
        || fail "bundled NOTICE.txt does not match the retained model-origin notice"
    plutil -lint "$PRIVACY_MANIFEST_SOURCE" >/dev/null \
        || fail "the source privacy manifest is missing or invalid"
    [[ -f "$resources_path/PrivacyInfo.xcprivacy" ]] \
        || fail "the built app is missing PrivacyInfo.xcprivacy"
    plutil -lint "$resources_path/PrivacyInfo.xcprivacy" >/dev/null \
        || fail "the bundled privacy manifest is invalid"
    cmp -s \
        <(plutil -convert xml1 -o - "$PRIVACY_MANIFEST_SOURCE") \
        <(plutil -convert xml1 -o - "$resources_path/PrivacyInfo.xcprivacy") \
        || fail "bundled PrivacyInfo.xcprivacy does not match the reviewed source manifest"

    verify_model_inventory "$resources_path"

    executable_name="$(plist_value "$info_plist" CFBundleExecutable || true)"
    [[ -n "$executable_name" ]] || fail "CFBundleExecutable is missing"
    executable_path="$app_path/Contents/MacOS/$executable_name"
    [[ -f "$executable_path" ]] || fail "the main app executable is missing"
    verify_universal_binary "$executable_path"
    if otool -L "$executable_path" | grep -qi sparkle; then
        fail "the App Store executable must not link Sparkle"
    fi
    if nm -gU "$executable_path" 2>/dev/null \
        | grep -Ei '(^|_)espeak(_|$)|espeak-ng|piper[_-]?phonemize' >/dev/null; then
        fail "the app executable contains prohibited optional TTS symbols"
    fi
    if nm -gU "$executable_path" 2>/dev/null \
        | grep -F '$s10FluidAudio' >/dev/null; then
        fail "the app executable links the full FluidAudio package"
    fi
}

verify_universal_binary() {
    local executable_path="$1"
    local actual_architectures expected_architectures
    actual_architectures="$(
        lipo -archs "$executable_path" \
            | tr ' ' '\n' \
            | sed '/^$/d' \
            | LC_ALL=C sort -u
    )"
    expected_architectures="$(printf '%s\n' arm64 x86_64 | LC_ALL=C sort)"
    [[ "$actual_architectures" == "$expected_architectures" ]] \
        || fail "the app executable must contain exactly arm64 and x86_64 (found: ${actual_architectures//$'\n'/, })"
}

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-app-store-verify.XXXXXX")"
cleanup_temp() {
    if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
        find "$TEMP_ROOT" -depth -delete
    fi
}
trap cleanup_temp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_app_store_signature() {
    local app_path="$1"
    local signing_details embedded_team entitlements_plist
    local actual_entitlement_keys expected_entitlement_keys entitlement_difference

    codesign --verify --deep --strict --verbose=2 "$app_path" \
        || fail "the exported app signature is invalid"
    signing_details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
    embedded_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signing_details" | head -n1)"
    [[ "$embedded_team" == "$EXPECTED_TEAM_ID" ]] \
        || fail "the app signature team is ${embedded_team:-missing}, expected $EXPECTED_TEAM_ID"
    grep -Eq "^Authority=(Apple Distribution|3rd Party Mac Developer Application): .+ \\($EXPECTED_TEAM_ID\\)$" \
        <<<"$signing_details" \
        || fail "the app is not signed with an Apple Distribution/Mac App Store identity for $EXPECTED_TEAM_ID"
    grep -q '^Identifier=com[.]tmoreton[.]yaprflow$' <<<"$signing_details" \
        || fail "the code signature identifier is not $EXPECTED_BUNDLE_ID"
    grep -q '^CodeDirectory .*flags=.*runtime' <<<"$signing_details" \
        || fail "the exported signature does not enable the hardened runtime"

    entitlements_plist="$TEMP_ROOT/app-entitlements.plist"
    codesign -d --entitlements :- "$app_path" >"$entitlements_plist" 2>/dev/null \
        || fail "could not extract signed app entitlements"
    plutil -lint "$entitlements_plist" >/dev/null \
        || fail "signed app entitlements are not a valid plist"
    require_plist_value "$entitlements_plist" com.apple.application-identifier "$EXPECTED_APPLICATION_ID"
    require_plist_value "$entitlements_plist" com.apple.developer.team-identifier "$EXPECTED_TEAM_ID"
    require_plist_value "$entitlements_plist" com.apple.security.app-sandbox "true"
    require_plist_value "$entitlements_plist" com.apple.security.device.audio-input "true"
    require_plist_value "$entitlements_plist" com.apple.security.network.client "true"

    actual_entitlement_keys="$(
        /usr/libexec/PlistBuddy -c Print "$entitlements_plist" \
            | awk '
                /^[[:space:]]+[^[:space:]].*[[:space:]]=[[:space:]]/ {
                    key = $0
                    sub(/^[[:space:]]+/, "", key)
                    sub(/[[:space:]]+=[[:space:]].*$/, "", key)
                    print key
                }
            ' \
            | LC_ALL=C sort -u
    )"
    expected_entitlement_keys="$(
        printf '%s\n' \
            com.apple.application-identifier \
            com.apple.developer.team-identifier \
            com.apple.security.app-sandbox \
            com.apple.security.device.audio-input \
            com.apple.security.network.client \
            | LC_ALL=C sort
    )"
    if [[ "$actual_entitlement_keys" != "$expected_entitlement_keys" ]]; then
        entitlement_difference="$(
            comm -3 \
                <(printf '%s\n' "$expected_entitlement_keys") \
                <(printf '%s\n' "$actual_entitlement_keys")
        )"
        echo "error: signed entitlements are not the expected App Store set:" >&2
        printf '%s\n' "$entitlement_difference" >&2
        exit 1
    fi

    if plist_value "$entitlements_plist" com.apple.security.network.server >/dev/null 2>&1; then
        fail "the signed App Store app must not contain the server network entitlement"
    fi
    if [[ "$(plist_value "$entitlements_plist" com.apple.security.get-task-allow || true)" == "true" ]]; then
        fail "the signed App Store app unexpectedly allows debugger attachment"
    fi
}

verify_provisioning_profile() {
    local app_path="$1"
    local embedded_profile="$app_path/Contents/embedded.provisionprofile"
    local profile_plist="$TEMP_ROOT/embedded-profile.plist"
    local expiration expiration_epoch current_epoch profile_name

    [[ -s "$embedded_profile" ]] || fail "the exported app has no embedded provisioning profile"
    security cms -D -i "$embedded_profile" >"$profile_plist" 2>/dev/null \
        || fail "the embedded provisioning profile cannot be decoded"
    plutil -lint "$profile_plist" >/dev/null \
        || fail "the embedded provisioning profile is invalid"
    require_plist_value "$profile_plist" TeamIdentifier:0 "$EXPECTED_TEAM_ID"
    require_plist_value "$profile_plist" Platform:0 "OSX"
    require_plist_value "$profile_plist" Entitlements:com.apple.application-identifier "$EXPECTED_APPLICATION_ID"
    require_plist_value "$profile_plist" Entitlements:com.apple.developer.team-identifier "$EXPECTED_TEAM_ID"

    expiration="$(plist_raw "$profile_plist" ExpirationDate || true)"
    [[ -n "$expiration" ]] || fail "the provisioning profile has no expiration date"
    expiration_epoch="$(
        date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null || true
    )"
    [[ -n "$expiration_epoch" ]] || fail "could not parse provisioning profile expiration: $expiration"
    current_epoch="$(date '+%s')"
    [[ "$expiration_epoch" -gt "$current_epoch" ]] \
        || fail "the provisioning profile expired at $expiration"

    profile_name="$(plist_value "$profile_plist" Name || true)"
    echo "==> Verified provisioning profile: ${profile_name:-unnamed} (expires $expiration)"
}

verify_installer_package() {
    local package_path="$1"
    local signature_details package_expand_dir extracted_app app_count

    [[ -s "$package_path" ]] || fail "the exported installer package is missing or empty"
    if ! signature_details="$(pkgutil --check-signature "$package_path" 2>&1)"; then
        echo "$signature_details" >&2
        fail "the installer package signature is invalid"
    fi
    grep -Eq "^[[:space:]]*1[.] 3rd Party Mac Developer Installer: .+ \\($EXPECTED_TEAM_ID\\)[[:space:]]*$" \
        <<<"$signature_details" \
        || fail "the package is not signed with the Mac App Store installer identity for $EXPECTED_TEAM_ID"

    package_expand_dir="$TEMP_ROOT/expanded-package"
    pkgutil --expand-full "$package_path" "$package_expand_dir" \
        || fail "could not safely expand the signed installer package"
    app_count="$(
        find "$package_expand_dir" -type d -name "$APP_NAME.app" -prune -print \
            | awk 'END { print NR + 0 }'
    )"
    [[ "$app_count" == "1" ]] \
        || fail "the installer package must contain exactly one $APP_NAME.app (found $app_count)"
    extracted_app="$(
        find "$package_expand_dir" -type d -name "$APP_NAME.app" -prune -print \
            | head -n1
    )"

    verify_app_payload "$extracted_app"
    verify_app_store_signature "$extracted_app"
    verify_provisioning_profile "$extracted_app"
}

validate_export_options
validate_checksum_manifest

PROVISIONING_FLAG=""
if [[ "${ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
    PROVISIONING_FLAG="-allowProvisioningUpdates"
else
    SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! grep -Eq "\"(Apple Distribution|3rd Party Mac Developer Application): .+ \\($EXPECTED_TEAM_ID\\)\"" \
        <<<"$SIGNING_IDENTITIES"; then
        cat >&2 <<EOF
error: no valid Apple Distribution/Mac App Store signing identity was found for
team $EXPECTED_TEAM_ID. Install the current distribution certificate, or set
ALLOW_PROVISIONING_UPDATES=1 to let an authenticated Xcode manage signing.
EOF
        exit 1
    fi
fi

DEFAULT_OUTPUT_DIR="$ROOT/build/app-store/$VERSION-$BUILD_NUMBER"
OUTPUT_DIR="${APP_STORE_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
if [[ -e "$OUTPUT_DIR" ]]; then
    fail "output directory already exists: $OUTPUT_DIR (move or remove it before retrying)"
fi

echo "==> Running shared transcription-policy tests"
swift test

echo "==> Verifying the pinned source model inventory"
"$ROOT/scripts/fetch-models.sh"
verify_model_inventory "$ROOT"

mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir "$OUTPUT_DIR"
ARCHIVE_PATH="$OUTPUT_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$OUTPUT_DIR/export"

echo "==> Archiving $APP_NAME $VERSION ($BUILD_NUMBER) for the Mac App Store"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    ${PROVISIONING_FLAG:+"$PROVISIONING_FLAG"} \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
    archive

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[[ -d "$ARCHIVED_APP" ]] || fail "archive did not contain $ARCHIVED_APP"
echo "==> Verifying archived app contents before export"
verify_app_payload "$ARCHIVED_APP"

echo "==> Exporting a signed App Store installer (no upload)"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    ${PROVISIONING_FLAG:+"$PROVISIONING_FLAG"}

PACKAGE_COUNT="$(
    find "$EXPORT_DIR" -maxdepth 2 -type f -name '*.pkg' -print \
        | awk 'END { print NR + 0 }'
)"
[[ "$PACKAGE_COUNT" == "1" ]] \
    || fail "App Store export must produce exactly one signed .pkg (found $PACKAGE_COUNT)"
PACKAGE_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -type f -name '*.pkg' -print | head -n1)"

echo "==> Verifying signed installer and exported app"
verify_installer_package "$PACKAGE_PATH"

echo
echo "==> Mac App Store release package verified successfully"
echo "    Version: $VERSION ($BUILD_NUMBER)"
echo "    Package: $PACKAGE_PATH"
echo "    SHA-256: $(shasum -a 256 "$PACKAGE_PATH" | awk '{print $1}')"
echo "    This script did not upload the package."
