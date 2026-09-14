<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow</h1>
  <p><strong>Private voice productivity for Apple devices, with on-device AI tools on supported Macs.</strong></p>
  <p>Press Command-T. Speak. Press Command-T again. Paste clean text anywhere.</p>
</div>

---

Yaprflow is the voice and AI productivity app planned for a privacy-first
software bundle. The Mac app records microphone input, transcribes speech locally,
copies the finished text to the clipboard, and keeps a local Markdown
archive. Long-form dictation can be turned into summaries, structured notes,
or other useful text with Apple's on-device Foundation Models on supported
Macs.

Useful software without another subscription: the Mac App Store release is a
US $29.00 one-time purchase, with Apple providing comparable local prices in
other regions. There is no Yaprflow account, advertising, tracking, or cloud
transcription service. The source remains available for inspection and
licensed source builds.

## Highlights

- **Local by design**: microphone audio and transcripts are processed on the
  device; there is no first-party backend or runtime telemetry.
- **One hotkey workflow on Mac**: start and stop dictation with Command-T, or
  change the shortcut from the menu-bar item.
- **Polished or exact text**: choose a cleaned-up result or retain the model's
  wording more closely.
- **Local vocabulary**: deterministic phrase replacements for names, acronyms,
  product terms, and preferred spellings.
- **On-device AI**: summarize, rewrite, structure, or transform the latest or
  any saved transcript with a custom prompt using Apple Intelligence on
  supported Macs. Long transcripts are divided and recombined automatically.
- **Smart Markdown archive**: each completed Mac transcript is saved locally;
  on supported Macs, Apple Intelligence adds a title, topic, and description.
- **True streaming multilingual transcription**: a bundled Nemotron 3.5 ASR
  0.6B 1120 ms chunk-size export produces local partial results in 32
  production-ready locales. On Mac, English (United States) is the default;
  choose a different locale or Automatic in Settings, with no cloud round
  trips.
- **Inspectable source**: current Yaprflow-owned code is source-available under
  PolyForm Shield 1.0.0; the historical Apache-2.0 boundary is preserved.

Yaprflow captures microphone speech and transcript text. It does not capture
system audio or retain raw meeting recordings.

## Install

The official commercial installation and update channel will be the Mac App
Store, with a US $29.00 base price paid once and Apple's comparable local
prices in other regions. Its product page will be linked here after Apple makes
the listing public. A separate Yaprflow account is not required; the Apple
Account used for the App Store purchase is sufficient.

Historically published GitHub DMGs remain available as legacy Apache-2.0
releases, but they are not the distribution channel for the current commercial
generation. Developers may clone and build the source under its applicable
license.

The Mac app requires macOS 14 Sonoma or later. The repository also contains an
iPhone/iPad app target requiring iOS 17 or later; its App Store listing
and commercial relationship to the Mac app are not yet finalized.

All speech-recognition models ship inside official apps. The Mac app starts
preparing its recognizer in the background at launch. Recording before that
preparation finishes—or after the recognizer has been released while idle—can
take a little longer while the on-device runtimes initialize.

## Using Yaprflow on Mac

Yaprflow runs as a menu-bar app. Click the waveform icon to open the menu.

- **Transcribe** starts or stops dictation.
- **Change shortcut**: open Settings, click the keyboard shortcut button, then
  press the new key combination. Escape cancels shortcut capture.
- **Choose speech language**: Settings defaults to English (United States) for
  more consistent English dictation. Choose any other supported locale, or
  Automatic when a recording may use different languages.
- **AI Summary, History, and Settings** opens a single tabbed window for
  transforming transcripts, browsing local history, and changing settings.
- **Command-Q** quits the app.

While dictating, Yaprflow shows a compact black overlay near the Mac notch or
top of the screen. It displays live partial text while listening and changes to
`Copied to clipboard` when the final text is ready.

## Vocabulary

The vocabulary file is plain Markdown. Open it from the menu-bar item with
`Vocabulary`, then add one replacement per line:

```text
spoken phrase => preferred spelling
yapper flow => Yaprflow
swift you eye => SwiftUI
dot net => .NET
```

Supported separators are `=>`, `->`, and `=`. Blank lines and lines beginning
with `#` are ignored.

## Privacy and local data

At runtime, Yaprflow does not contact a Yaprflow-operated service, download
models, upload audio, or require a login. The optional Mac AI features use
Apple's on-device Foundation Models framework. See the published
[Privacy Policy](https://yaprflow.com/privacy.html) for the full disclosure.

On macOS, Yaprflow writes user data into its existing sandbox container's
Application Support directory:

- Transcripts: `Yaprflow/Transcripts/*.md`
- Vocabulary: `Yaprflow/Vocabulary.md`
- Preferences: bundle domain `com.tmoreton.yaprflow`

Use the `Folder` action in History to reveal saved transcripts. Raw microphone
audio is held only for processing and is not retained after transcription.

On iOS, up to three recent transcript strings and preferences are stored in the
app's separate local container. There is currently no Mac/iOS sync.

## How it works

The macOS app is built with AppKit, SwiftUI, AVFoundation,
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and ONNX Runtime for ASR,
and Core ML with a narrow Apache-licensed adapter derived from
[FluidAudio](https://github.com/FluidInference/FluidAudio) for voice activity
detection. The full FluidAudio package is not linked into the apps.

1. The global hotkey toggles `TranscriptionController`.
2. `AudioCapture` records microphone buffers with `AVAudioEngine`.
3. A reusable `AVAudioConverter` resamples the stream and the bundled Silero
   Core ML VAD finds speech endpoints.
4. The same audio is decoded continuously by the bundled 1120 ms chunk-size
   Nemotron 3.5 multilingual streaming model through an ASR-only sherpa-onnx
   build using greedy search and the saved speech-language prompt. English
   (United States) is the default, and Automatic detection remains available.
5. Yaprflow applies local cleanup and vocabulary replacements.
6. Final text is copied to the clipboard and saved as Markdown.
7. When available, Apple Foundation Models can summarize, restructure, or
   enrich transcript text locally.

The complete Nemotron 3.5 ASR and Silero VAD models are bundled in official
apps. On Mac, background preparation begins at launch, the speech recognizer
stays warm between nearby dictations, and its large ONNX allocation is released
after five idle minutes or memory pressure. A later cold start initializes it
again. Network access is used only while preparing a source build when the
pinned model files are absent.

The upstream Nemotron 3.5 model covers 40 language-locales across 35 languages.
NVIDIA classifies 19 locales as transcription-ready, 13 as broad-coverage, and
8 as adaptation-ready. The Mac app makes the 32 out-of-box locales selectable
and also offers Automatic detection. The current iOS source target uses
Automatic detection. The 8 adaptation-ready locales require fine-tuning and
are not advertised as production-ready.

## Repository layout

```text
yaprflow/                       macOS menu-bar app
yaprflow-iOS/                   iPhone and iPad app target
yaprflow.xcodeproj/             Xcode project and shared schemes
docs/                           yaprflow.com static website and bundle brief
scripts/fetch-models.sh         fetches and verifies pinned build-time models
scripts/copy-models.sh          verifies and stages the exact Xcode model payload
scripts/build-sherpa-onnx-asr.sh builds pinned Apple native ASR-only frameworks
scripts/publish-models.sh       maintains the public source-build model mirror
scripts/app-store-release.sh    archives and verifies Mac App Store packages
scripts/ios-app-store-release.sh archives and verifies iOS App Store packages
scripts/release.sh              creates local DMGs or source-only GitHub releases
LICENSES/                       preserved historical and third-party license text
THIRD_PARTY_NOTICES.md          dependency and model provenance
```

## Build from source

Requirements:

- macOS 14 or later
- Xcode 26 or later with command-line tools (the Mac target imports Apple's
  Foundation Models framework while remaining deployable to macOS 14)
- CMake 3.24 or later for the initial native ASR runtime build
- Network access for the initial, checksum-verified dependency and model fetch
- Hugging Face CLI (`brew install huggingface-cli`) for the bundled Silero VAD;
  the Nemotron ONNX fallback comes from the pinned official sherpa-onnx release.

```bash
git clone https://github.com/tmoreton/yaprflow.git
cd yaprflow
scripts/build-sherpa-onnx-asr.sh
scripts/fetch-models.sh
open yaprflow.xcodeproj
```

Build the Mac app from the command line:

```bash
xcodebuild \
  -project yaprflow.xcodeproj \
  -scheme yaprflow \
  -destination 'platform=macOS' \
  build
```

Run the shared transcription-policy unit tests without building an app target:

```bash
swift test
```

The shared schemes are:

- `yaprflow`: macOS, bundle ID `com.tmoreton.yaprflow`, version 5.0.1 (5).
- `yaprflow-iOS`: iPhone/iPad, bundle ID `com.tmoreton.yaprflow.ios`, version
  1.0.0 (2).

The fetch script pins exact Hugging Face revisions and validates every bundled
model file with `scripts/model-checksums.sha256`.
Reviewed native sherpa-onnx and ONNX Runtime artifacts are independently pinned
by `scripts/native-asr-checksums.sha256`.

## Distribution and releases

Production binaries are archived, signed, and submitted through Apple's App
Store workflow. They are not attached automatically to public GitHub releases.

After the release commit is clean, create and verify the signed Mac App Store
archive and installer with:

```bash
scripts/app-store-release.sh
```

Create and verify the iPhone/iPad archive and exported App Store `.ipa` with:

```bash
scripts/ios-app-store-release.sh
```

Set `ALLOW_PROVISIONING_UPDATES=1` if authenticated Xcode must download or
manage signing assets. If the iOS App Store Connect record or distribution
profile is not ready yet, set `IOS_ARCHIVE_ONLY=1` to produce and validate the
signed archive without attempting export. Both entrypoints stop after local
export and never upload to App Store Connect. They print the verified package
location and SHA-256 digest and reject model drift, missing notices, unexpected
permissions or capabilities, and native binaries containing excluded optional
TTS code.

For a local unsigned test DMG:

```bash
SKIP_NOTARIZE=1 scripts/release.sh
```

For an annotated tag and source-only GitHub release after the release commit is
clean and ready:

```bash
scripts/release.sh 5.0.1 --publish-source
```

That command builds a local DMG for validation, but it does not upload the
DMG. The retired `--publish` option now fails closed so it cannot accidentally
publish a production binary. Existing historical binary releases are not
deleted or rewritten.

## License and branding

Yaprflow-owned software in releases through version 4.0.14 and repository
revisions through commit
`0af74ab27f24933d16c004336cf63eac95c0a6b0` remains available under Apache
License 2.0. Later revisions, beginning with the 5.0.0 release line, are offered
under PolyForm Shield License 1.0.0; the transition was adopted September 11,
2026. See [LICENSE](LICENSE) for the complete terms.

Third-party libraries and models retain their own licenses. Nemotron 3.5 ASR
model materials are available under OpenMDW-1.1, sherpa-onnx is Apache-2.0,
and ONNX Runtime and Silero VAD use MIT terms. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the in-app
Acknowledgements.

The Yaprflow name, icon, logo, domain, and associated branding are not licensed
for competing distributions. See [TRADEMARKS.md](TRADEMARKS.md).

## Support

See [yaprflow.com/support.html](https://yaprflow.com/support.html) or email
<tim@yaprflow.com>.
