#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
asset_dir="$repo_dir/AppStore/Assets"
output_dir="$repo_dir/AppStore/Screenshots"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-screenshots.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

background="$asset_dir/yaprflow-app-store-background.png"
icon="$repo_dir/docs/icon.png"
font_regular="Helvetica-Neue"
font_medium="Helvetica-Neue-Medium"
font_bold="Helvetica-Neue-Bold"

for required in \
  "$background" \
  "$icon" \
  "$asset_dir/onboarding-window.png" \
  "$asset_dir/live-transcript-overlay.png" \
  "$asset_dir/settings-window.png" \
  "$asset_dir/copied-overlay.png"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required screenshot asset: $required" >&2
    exit 1
  fi
done

mkdir -p "$output_dir"

magick "$background" \
  -resize '2560x1600^' \
  -gravity center \
  -extent 2560x1600 \
  "$work_dir/base.png"

make_base() {
  local destination="$1"

  magick "$work_dir/base.png" \
    -gravity northwest \
    \( "$icon" -resize 54x54 \) -geometry +140+94 -composite \
    -font "$font_bold" -pointsize 32 -fill '#0D0F10' \
    -annotate +214+99 'Yaprflow' \
    "$destination"
}

make_badge() {
  local source="$1"
  local destination="$2"
  local label="$3"

  magick "$source" \
    -gravity northwest \
    -fill 'rgba(255,255,255,0.86)' -stroke '#E7E9E7' -strokewidth 2 \
    -draw 'roundrectangle 140,190 570,256 33,33' \
    -fill '#EF4444' -stroke none -draw 'circle 174,223 183,223' \
    -font "$font_medium" -pointsize 22 -fill '#06695C' \
    -annotate +198+204 "$label" \
    "$destination"
}

make_shadowed() {
  local source="$1"
  local destination="$2"

  magick "$source" \
    \( +clone -background '#0D0F10' -shadow 24x28+0+22 \) \
    +swap -background none -layers merge +repage \
    "$destination"
}

add_feature_cards() {
  local source="$1"
  local destination="$2"

  magick "$source" \
    -gravity northwest \
    -fill 'rgba(255,255,255,0.90)' -stroke '#E7E9E7' -strokewidth 2 \
    -draw 'roundrectangle 140,1260 850,1450 28,28' \
    -draw 'roundrectangle 925,1260 1635,1450 28,28' \
    -draw 'roundrectangle 1710,1260 2420,1450 28,28' \
    -stroke none -fill '#0D0F10' -font "$font_bold" -pointsize 38 \
    -annotate +190+1342 'Live transcript' \
    -annotate +975+1342 '25 languages' \
    -annotate +1760+1342 'On-device' \
    -fill '#71787C' -font "$font_regular" -pointsize 27 \
    -annotate +190+1393 'See every word as you speak' \
    -annotate +975+1393 'Automatically detected' \
    -annotate +1760+1393 'No cloud audio' \
    "$destination"
}

# 1. Private, offline dictation
make_base "$work_dir/01-base.png"
make_badge "$work_dir/01-base.png" "$work_dir/01-badge.png" 'Private voice-to-text for Mac'
make_shadowed "$asset_dir/onboarding-window.png" "$work_dir/onboarding-shadow.png"

magick "$work_dir/01-badge.png" \
  -gravity northwest \
  -font "$font_bold" -pointsize 116 -kerning -3 -interline-spacing 8 -fill '#0D0F10' \
  -annotate +140+400 $'Private dictation.\nOn your Mac.' \
  -font "$font_regular" -pointsize 42 -kerning 0 -interline-spacing 14 -fill '#3C4144' \
  -annotate +145+715 $'Fast, accurate speech-to-text\nwith no account or cloud upload.' \
  -font "$font_bold" -pointsize 28 -fill '#06695C' \
  -annotate +145+1370 'NO ACCOUNTS  •  NO ADS  •  NO TRACKING' \
  \( "$work_dir/onboarding-shadow.png" -resize 790x835 \) -geometry +1560+332 -composite \
  "$output_dir/01-private-offline-dictation.png"

# 2. Live transcription
make_base "$work_dir/02-base.png"
make_badge "$work_dir/02-base.png" "$work_dir/02-badge.png" 'Private voice-to-text for Mac'
make_shadowed "$asset_dir/live-transcript-overlay.png" "$work_dir/live-shadow.png"

magick "$work_dir/02-badge.png" \
  -gravity northwest \
  -font "$font_bold" -pointsize 108 -kerning -3 -interline-spacing 8 -fill '#0D0F10' \
  -annotate +140+395 $'Speak anywhere.\nSee every word.' \
  -font "$font_regular" -pointsize 42 -kerning 0 -fill '#3C4144' \
  -annotate +145+680 'Press Command-T and dictate in any Mac app.' \
  \( "$work_dir/live-shadow.png" -resize 1944x248 \) -geometry +308+820 -composite \
  "$work_dir/02-content.png"

add_feature_cards "$work_dir/02-content.png" "$output_dir/02-live-transcription.png"

# 3. Private by design
make_base "$work_dir/03-base.png"

magick "$work_dir/03-base.png" \
  -gravity northwest \
  -font "$font_bold" -pointsize 25 -fill '#06695C' \
  -annotate +145+238 'WHY YAPRFLOW' \
  -font "$font_bold" -pointsize 116 -kerning -3 -interline-spacing 8 -fill '#0D0F10' \
  -annotate +140+390 $'Private by\ndesign.' \
  -font "$font_regular" -pointsize 42 -kerning 0 -interline-spacing 18 -fill '#3C4144' \
  -annotate +145+715 $'Speech stays on-device.\nNo sign-in required.\nNo analytics or tracking.' \
  -fill '#E6F7F3' -stroke none -draw 'roundrectangle 140,1080 510,1142 31,31' \
  -font "$font_bold" -pointsize 25 -fill '#06695C' \
  -annotate +173+1097 'CORE ML  •  PRIVATE' \
  "$work_dir/03-copy.png"

make_shadowed "$asset_dir/settings-window.png" "$work_dir/settings-shadow.png"
magick "$work_dir/03-copy.png" \
  -gravity northwest \
  \( "$work_dir/settings-shadow.png" -resize 1080x1052 \) -geometry +1320+278 -composite \
  "$output_dir/03-private-by-design.png"

# 4. Ready to paste
make_base "$work_dir/04-base.png"
make_badge "$work_dir/04-base.png" "$work_dir/04-badge.png" 'Private voice-to-text for Mac'
make_shadowed "$asset_dir/copied-overlay.png" "$work_dir/copied-shadow.png"

magick "$work_dir/04-badge.png" \
  -gravity northwest \
  -font "$font_bold" -pointsize 116 -kerning -3 -fill '#0D0F10' \
  -annotate +140+430 'Ready to paste.' \
  -font "$font_regular" -pointsize 42 -kerning 0 -interline-spacing 14 -fill '#3C4144' \
  -annotate +145+620 $'Your finished text is copied automatically—\nready for email, notes, or any Mac app.' \
  \( "$work_dir/copied-shadow.png" -resize 1944x248 \) -geometry +308+860 -composite \
  -fill '#101314' -stroke none -draw 'roundrectangle 140,1260 2420,1450 34,34' \
  -font "$font_bold" -pointsize 40 -fill '#FFFFFF' \
  -annotate +730+1343 'One shortcut. Zero friction.' \
  -font "$font_regular" -pointsize 28 -fill '#B8C0C4' \
  -annotate +830+1395 'Press Command-T, speak, press again, paste.' \
  "$output_dir/04-ready-to-paste.png"

for screenshot in "$output_dir"/*.png; do
  flattened="$work_dir/$(basename "$screenshot")"
  magick "$screenshot" \
    -background '#FAFAF8' \
    -alpha remove \
    -alpha off \
    -colorspace sRGB \
    "PNG24:$flattened"
  mv "$flattened" "$screenshot"

  dimensions="$(magick identify -format '%wx%h' "$screenshot")"
  if [[ "$dimensions" != '2560x1600' ]]; then
    echo "Unexpected dimensions for $screenshot: $dimensions" >&2
    exit 1
  fi
done

echo "Created four 2560x1600 App Store screenshots in $output_dir"
