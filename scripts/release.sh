#!/usr/bin/env bash
# Builds yaprflow.app, signs + notarizes + staples it, packages it into a styled
# DMG, and (optionally) tags the commit and uploads the DMG to GitHub Releases.
#
# Usage:
#   scripts/release.sh                                    # local DMG build (uses MARKETING_VERSION)
#   scripts/release.sh 3.0.1                              # local DMG build with explicit version
#   scripts/release.sh 3.0.1 --publish                    # build + tag + GitHub release
#   scripts/release.sh 3.0.0 --publish                    # rebuild and replace existing v3.0.0 DMG
#   scripts/release.sh 3.1.0 --publish --draft
#   scripts/release.sh 3.1.0 --publish --prerelease --notes "Adds launch-at-login"
#   SKIP_NOTARIZE=1 scripts/release.sh                    # unsigned local test build
#
# Notarization credentials: by default this uses the `notary-yaprflow` keychain
# profile (created via `xcrun notarytool store-credentials`). Override with
# NOTARY_PROFILE=<name>, or with APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD.

set -euo pipefail

cd "$(dirname "$0")/.."

# ---- Args --------------------------------------------------------------------

VERSION=""
PUBLISH=false
NOTES=""
EXTRA_GH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish)
            PUBLISH=true
            shift
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

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

read_marketing_version() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^\s*MARKETING_VERSION = /{print $2; exit}'
}

if [[ -z "$VERSION" ]]; then
    VERSION="$(read_marketing_version)"
fi
if [[ -z "$VERSION" ]]; then
    echo "error: could not determine version (pass it as the first argument)" >&2
    exit 1
fi

DMG_NAME="$APP_NAME-$VERSION"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
TEMP_DMG="$BUILD_DIR/$DMG_NAME.tmp.dmg"
APP_ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
TAG="v$VERSION"

# ---- Decide whether to sign + notarize ---------------------------------------

NOTARIZE=true
NOTARY_AUTH=()

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> SKIP_NOTARIZE=1 set; building unsigned/unnotarized DMG for local testing"
    NOTARIZE=false
else
    # Default to the keychain profile already used by scripts/notarize-dmg.sh.
    NOTARY_PROFILE="${NOTARY_PROFILE:-notary-yaprflow}"

    if [[ -n "${NOTARY_PROFILE}" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
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
    local status
    while :; do
        sleep 20
        status=$(notarize_status "$sub_id" || true)
        echo "    $label: ${status:-unknown} (id: $sub_id)"
        case "$status" in
            Accepted) return 0 ;;
            "In Progress"|"") continue ;;
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

# ---- Pre-publish guards ------------------------------------------------------

if [[ "$PUBLISH" == true ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh (GitHub CLI) is not installed. brew install gh" >&2
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "error: gh is not authenticated. run: gh auth login" >&2
        exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: working tree has uncommitted changes — commit or stash before --publish" >&2
        git status --short >&2
        exit 1
    fi
fi

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
    # ---- Ensure model files are on disk -------------------------------------

    # The Xcode build phase rsyncs ./Models into the bundle. If a fresh clone
    # hasn't run scripts/fetch-models.sh, the resulting .app would ship without
    # the Parakeet small files / Silero VAD and silently fail at first launch.
    if [[ ! -f "Models/parakeet-tdt-0.6b-v2/parakeet_vocab.json" ]]; then
        echo "==> Models missing — running scripts/fetch-models.sh"
        scripts/fetch-models.sh
    fi

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
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" || true
fi

echo
echo "==> Built: $DMG_PATH"
ls -lh "$DMG_PATH"

# ---- Publish to GitHub Releases ---------------------------------------------

if [[ "$PUBLISH" == true ]]; then
    echo
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "==> Tag $TAG already exists locally — skipping create"
    else
        echo "==> Tagging $TAG"
        git tag -a "$TAG" -m "yaprflow $VERSION"
    fi

    if git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "refs/tags/$TAG"; then
        echo "==> Tag $TAG already on origin — skipping push"
    else
        git push origin "$TAG"
    fi

    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "==> Release $TAG exists — replacing DMG asset"
        gh release upload "$TAG" "$DMG_PATH" --clobber
        if [[ -n "$NOTES" ]]; then
            gh release edit "$TAG" --notes "$NOTES"
        fi
    else
        echo "==> Creating GitHub release"
        RELEASE_ARGS=("$TAG" "$DMG_PATH" --title "yaprflow $VERSION")
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
    echo "==> Released $TAG"
fi
