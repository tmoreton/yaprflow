<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow</h1>
  <p><strong>Private, offline voice dictation for macOS.</strong></p>
  <p>Press Command-T. Speak. Press Command-T again. Paste clean text anywhere.</p>
</div>

---

Yaprflow is a small menu-bar dictation app for macOS. It records from your
microphone, transcribes speech locally with Core ML models, copies the finished
text to the clipboard, and keeps a local Markdown archive of completed
transcripts.

## Highlights

- **Local by default**: audio is processed on your Mac; there are no accounts,
  servers, or telemetry.
- **One hotkey workflow**: start and stop dictation with Command-T, or change
  the shortcut from the menu-bar item.
- **Polished text**: common filler sounds are removed before text reaches your
  clipboard.
- **Local vocabulary**: deterministic phrase replacements for names, acronyms,
  product terms, and preferred spellings.
- **Markdown archive**: each completed transcript is saved locally with
  timestamp, mode, source app, and vocabulary replacement count.
- **Multilingual**: the Parakeet model supports 25 European languages with
  automatic detection.
- **Open source**: Apache 2.0.

## Install

1. Download the latest DMG from
   [GitHub Releases](https://github.com/tmoreton/yaprflow/releases/latest).
2. Drag `Yaprflow.app` into `/Applications`.
3. Launch Yaprflow and grant microphone access.
4. Press Command-T, speak, press Command-T again, then paste.

Yaprflow requires macOS 14 Sonoma or later.

On first use, Yaprflow may download the large Parakeet encoder model from this
repository's GitHub Releases and warm up Core ML. That download is model data,
not your audio.

## Using Yaprflow

Yaprflow runs as a menu-bar app. Click the waveform icon to open the menu.

- **Transcribe**: starts or stops dictation. The shortcut is shown on the right.
- **Change shortcut**: click the shortcut text in the menu, then press the new
  key combination. Escape cancels shortcut capture.
- **Copy Transcript**: copies the most recent completed transcript again.
- **Vocabulary**: opens the local vocabulary file.
- **Privacy**: shows local processing status and vocabulary entry count.
- **Recordings**: opens the local transcript archive folder.
- **Command-Q**: quits the app.

While dictating, Yaprflow shows a compact black overlay near the Mac notch or
top of the screen. It displays live partial text while listening and changes to
`Copied to clipboard` when the final text is ready.

## Vocabulary

The vocabulary file is plain Markdown. Open it from the menu-bar item with
`Vocabulary`.

Add one replacement per line:

```text
spoken phrase => preferred spelling
yapper flow => Yaprflow
swift you eye => SwiftUI
parakeet t d t => Parakeet TDT
```

Supported separators are `=>`, `->`, and `=`. Blank lines and lines beginning
with `#` are ignored.

## Local Data

Yaprflow writes user data into the app container's Application Support
directory.

- Transcripts: `Yaprflow/Transcripts/*.md`
- Vocabulary: `Yaprflow/Vocabulary.md`
- Speech model cache: `FluidAudio/Models/parakeet-tdt-0.6b-v3`

Use the menu-bar `Recordings` and `Vocabulary` actions instead of memorizing
paths; sandboxed macOS apps place Application Support under their container.

## How It Works

The macOS app is built with AppKit, SwiftUI, AVFoundation, Core ML, and
[FluidAudio](https://github.com/FluidInference/FluidAudio).

Runtime flow:

1. The global hotkey toggles `TranscriptionController`.
2. `AudioCapture` records microphone buffers with `AVAudioEngine`.
3. Audio is resampled and streamed through FluidAudio VAD for speech segments.
4. Segments are transcribed with Parakeet TDT 0.6B v3 Core ML models.
5. Yaprflow applies local text cleanup and vocabulary replacements.
6. Final text is copied to the clipboard and saved as Markdown.

Model behavior:

- Small Parakeet model files are bundled with the app.
- The large `Encoder.mlmodelc` is downloaded and cached on first use when it is
  not bundled.
- Silero VAD is loaded from the bundle when present, with FluidAudio fallback
  behavior if it is missing.
- Models are loaded lazily on first dictation to avoid high memory use at
  launch.

## Repository Layout

```text
yaprflow/                 macOS menu-bar app
yaprflow-iOS/             iOS companion target
yaprflow.xcodeproj/       Xcode project and shared schemes
docs/                     GitHub Pages website for yaprflow.com
scripts/fetch-models.sh   downloads local development model files
scripts/release.sh        builds, signs, notarizes, and publishes DMGs
```

## Build From Source

Requirements:

- macOS 14 or later
- Xcode with command-line tools
- Network access to GitHub Releases for model downloads

Clone and fetch model files:

```bash
git clone https://github.com/tmoreton/yaprflow.git
cd yaprflow
scripts/fetch-models.sh
open yaprflow.xcodeproj
```

Build from the command line:

```bash
xcodebuild \
  -project yaprflow.xcodeproj \
  -scheme yaprflow \
  -destination 'platform=macOS' \
  build
```

The project has two shared schemes:

- `yaprflow`: macOS app, bundle id `com.tmoreton.yaprflow`, version 4.0.3.
- `yaprflow-iOS`: iOS target, bundle id `com.tmoreton.yaprflow.ios`.

## Release

For a local unsigned test DMG:

```bash
SKIP_NOTARIZE=1 scripts/release.sh
```

For a signed and notarized release, configure the notarization credentials
described in `scripts/release.sh`, then run:

```bash
scripts/release.sh 4.0.3 --publish
```

The release script can build the app, export a Developer ID signed app, notarize
and staple it, create the DMG, tag the release, and upload the DMG with the
GitHub CLI.

## Troubleshooting

- **Nothing records**: grant microphone permission in System Settings >
  Privacy & Security > Microphone.
- **The hotkey does not fire**: another app may own the shortcut. Open the
  Yaprflow menu and choose a different shortcut.
- **First dictation is slow**: the first run can download and warm up Core ML
  models. Later dictations should start faster.
- **Model download fails**: check network access to GitHub Releases, then quit
  and reopen Yaprflow to retry.
- **Need the last transcript again**: use `Copy Transcript` from the menu-bar
  item.

## License

Yaprflow is Apache 2.0. The bundled
[Parakeet TDT 0.6B v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
model is provided via FluidInference under CC-BY-4.0.
