<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow</h1>
  <p><strong>Private voice productivity for Apple devices, with your choice of AI provider on Mac.</strong></p>
  <p>Press Command-T. Speak. Press Command-T again. Paste clean text anywhere.</p>
</div>

---

Yaprflow is the voice and AI productivity app planned for a privacy-first
software bundle. The Mac app records microphone input, transcribes speech locally,
copies the finished text to the clipboard, and keeps a local Markdown
archive. Long-form dictation can be turned into summaries, structured notes,
or other useful text with Apple's on-device model, your own OpenAI or
OpenRouter key, or Ollama running on your Mac.

The Mac app is distributed as signed, notarized downloads from yaprflow.com.
There is no in-app sign-in, advertising, cross-app tracking, or cloud
transcription service. The source remains available for inspection and
licensed noncommercial builds.

## Highlights

- **Local transcription**: microphone audio is processed on the device;
  there is no first-party backend. Transcripts are sent to a cloud AI provider
  only when you select and use one.
- **Usage telemetry**: Mac users can share event counts and broad
  failure categories with Aptabase from Settings. It starts on and never
  includes audio, transcript text, prompts, or feedback messages.
- **One hotkey workflow on Mac**: start and stop dictation with Command-T, or
  change the shortcut from the menu-bar item.
- **Polished or exact text**: choose a cleaned-up result or retain the model's
  wording more closely.
- **Local vocabulary**: deterministic phrase replacements for names, acronyms,
  product terms, and preferred spellings.
- **AI Summary**: summarize, rewrite, structure, or transform the latest or
  any saved transcript with a custom prompt. Use Apple Intelligence on a
  supported Mac, your own OpenAI or OpenRouter key, or local Ollama. Long
  transcripts are divided and recombined automatically.
- **Smart Markdown archive**: each completed Mac transcript is saved locally;
  Apple Intelligence can add a title, topic, and description on supported Macs.
  Automatic titles with another provider require a separate opt-in.
- **True streaming multilingual transcription**: a bundled Nemotron 3.5 ASR
  0.6B 1120 ms chunk-size export produces local partial results in 32
  production-ready locales. On Mac, English (United States) is the default;
  choose a different locale or Automatic in Settings, with no cloud round
  trips.
- **Inspectable source**: current Yaprflow-owned code is source-available under
  PolyForm Noncommercial 1.0.0. Commercial use requires a separate license;
  the historical Apache-2.0 and PolyForm Shield boundaries are preserved.

Yaprflow captures microphone speech and transcript text. It does not capture
system audio or retain raw meeting recordings.

## Install

The Mac app is distributed as a paid, signed, notarized DMG through the
[Yaprflow website](https://yaprflow.com/). Live Stripe checkout delivers the
current private installer after purchase; see [`checkout/`](checkout/README.md)
for the verified deployment status. No App Store account is required to run it.

Developers may also clone and build the source for uses permitted by its
applicable license. Commercial source use requires a separate written license.
Official compiled purchases use the separate [customer license](EULA.md).

The Mac app requires macOS 14 Sonoma or later. The repository also contains an
iPhone/iPad source target requiring iOS 17 or later; it is separate from the
Mac direct download.

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
- **Send Feedback** is available in Settings for reporting a problem, making a
  suggestion, or asking a question. Review and send the prepared email in your
  mail app; no transcript or audio is attached.
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
speech models, upload audio, or require a login. Mac AI Summary uses Apple's
on-device model by default. If you select OpenAI or OpenRouter, the selected
transcript and prompt go directly to that provider using your own key. Ollama
uses its service on your Mac; Ollama cloud models may contact Ollama's cloud.
Automatic titles with these providers are a separate opt-in. See the published
[Privacy Policy](https://yaprflow.com/privacy.html) for the full disclosure.

The Mac telemetry switch sends fixed usage and failure events to
Aptabase when a release build has an app key. It is on by default, can be
turned off at any time, and includes no transcript or free-form text.

On macOS, Yaprflow writes user data into its existing sandbox container's
Application Support directory:

- Transcripts: `Yaprflow/Transcripts/*.md`
- Vocabulary: `Yaprflow/Vocabulary.md`
- Preferences: bundle domain `com.tmoreton.yaprflow`

Use the `Folder` action in History to reveal saved transcripts. Raw microphone
audio is held only for processing and is not retained after transcription.

On iOS, up to three recent transcript strings and preferences are stored in the
app's separate local container. There is currently no Mac/iOS sync.

The iPhone and iPad app also has a feedback button in its top bar. Feedback is
sent only when you choose to send the email draft. For a recommendation on
measuring app usage without changing this privacy behavior, see
[docs/ANALYTICS_PLAN.md](docs/ANALYTICS_PLAN.md).

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
7. The selected AI provider can summarize or restructure transcript text.
   Apple Intelligence is on-device; cloud providers receive a transcript only
   when used, and automatic cloud archive titles require opt-in.

The complete Nemotron 3.5 ASR and Silero VAD models are bundled in official
apps. On Mac, background preparation begins at launch, the speech recognizer
stays warm between nearby dictations, and its large ONNX allocation is released
after five idle minutes or memory pressure. A later cold start initializes it
again. Source builds may fetch pinned model files when they are absent.
At runtime, network access is used for optional cloud AI requests and enabled
usage telemetry.

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
docs/                           current GitHub Pages website and bundle brief
checkout/                       redesigned website, Stripe checkout, private downloads
scripts/fetch-models.sh         fetches and verifies pinned build-time models
scripts/copy-models.sh          verifies and stages the exact Xcode model payload
scripts/build-sherpa-onnx-asr.sh builds pinned Apple native ASR-only frameworks
scripts/publish-models.sh       maintains the public source-build model mirror
scripts/app-store-release.sh    creates and verifies Mac App Store packages
scripts/ios-app-store-release.sh historical iOS App Store packaging tool
scripts/release.sh              creates signed DMGs and direct-download releases
LICENSE                         current source license and historical boundaries
COMMERCIAL-LICENSING.md         separate commercial source-license inquiries
CONTRIBUTING.md                 issue and contribution policy
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

- `yaprflow`: direct-download macOS build with Sparkle, bundle ID
  `com.tmoreton.yaprflow`, version 5.1.4 (10).
- `yaprflow-AppStore`: Mac App Store build without Sparkle, using the same app
  identity and version so both editions are produced from the same source.
- `yaprflow-iOS`: iPhone/iPad, bundle ID `com.tmoreton.yaprflow.ios`, version
  1.0.0 (2).

The fetch script pins exact Hugging Face revisions and validates every bundled
model file with `scripts/model-checksums.sha256`.
Reviewed native sherpa-onnx and ONNX Runtime artifacts are independently pinned
by `scripts/native-asr-checksums.sha256`.

## Distribution and releases

The Mac app has two isolated distribution paths. The `yaprflow` scheme produces
a Developer ID signed and notarized DMG for paid website downloads. The
`yaprflow-AppStore` scheme produces an App Store signed package with no Sparkle
framework, feed settings, updater UI, or Sparkle installer entitlements. Apple
delivers updates for that edition. Both editions use the same marketing version
and build number for each release.

The website, Stripe checkout, and private download service live together in
[`checkout/`](checkout/README.md). The test purchase and private file delivery
have been verified in Vercel Preview. Production is live at the confirmed US
$7.99 one-time price and points to the verified Yaprflow 5.1.4 installer. The
original site remains preserved in `docs/`.
The release script verifies the bundled app,
entitlements, notices, privacy manifest, and model hashes before it publishes
anything.

For a local unsigned test DMG:

```bash
SKIP_NOTARIZE=1 scripts/release.sh
```

For a signed local DMG, configure a Developer ID identity and Apple
notarization credentials, put the Mac Aptabase app key in the ignored `.env`
(see `.env.example`), then run:

```bash
scripts/release.sh 5.1.4
```

The resulting DMG stays private until the paid checkout is configured.

### Direct-download updates

The Mac target uses Sparkle 2.10.0 for updates outside the App Store. The menu
and Settings include **Check for Updates…**, automatic checks default to once a
day, and verified updates can download and install when Yaprflow next relaunches.
Users can turn automatic checks or downloads off in Settings. Sparkle compares
the appcast's `sparkle:version` with the app's increasing `CFBundleVersion`;
every release must therefore increment `CURRENT_PROJECT_VERSION` as well as the
marketing version.

The stable feed is `https://yaprflow.com/appcast.xml`. The 5.1.4 bridge release
uses a signed empty feed because there is no newer update yet. To stage a signed
feed entry while producing a later notarized release, run:

```bash
DIRECT_BUILD_NUMBER=11 \
  SPARKLE_DOWNLOAD_URL_PREFIX=https://github.com/tmoreton/yaprflow/releases/download/v5.1.5/ \
  scripts/release.sh 5.1.5 --prepare-update
```

This writes the signed archive and appcast to `build/sparkle-update/`. Upload the
archive first, verify its HTTPS URL, then replace `checkout/appcast.xml` with the
generated feed and deploy the website. The private Sparkle EdDSA key is stored
in the macOS login Keychain under account `com.tmoreton.yaprflow`. The matching
key is also stored as the environment-scoped GitHub Actions secret
`SPARKLE_PRIVATE_KEY` in `sparkle-release`; only its public key is committed.
The workflow passes the secret to Sparkle through standard input and never
writes it into the repository or logs. Run
`scripts/configure-sparkle-github-secret.sh` to replace the secret from the
existing Keychain key.

For a later release, upload the signed and notarized DMG to an existing public
GitHub release, then run **Publish Sparkle update** in GitHub Actions with the
release tag and exact DMG asset name. The workflow downloads that fixed asset,
generates and verifies the archive and feed signatures, runs the website tests,
and commits the new appcast to `main`. Vercel then deploys the feed from the
Git-connected repository. The `sparkle-release` environment limits secret
access to this manual workflow.

The first updater-enabled Yaprflow release is 5.1.4 and requires a manual
website download because 5.1.3 does not contain Sparkle. Later releases can
update automatically. Sparkle validates the update archive before extraction
and requires the appcast itself to carry a valid EdDSA signature.
Yaprflow currently has no in-app license entitlement, so an update archive URL
that Sparkle can download without authentication is also downloadable outside
the app. Keep the feed empty until update hosting is deliberately made public
or a purchase-linked app entitlement is implemented.
The `--publish` option rejects public binary publication. A source-only release
is still available with `--publish-source`.

### Mac App Store updates

Build the matching Mac App Store release with the same public version and build
number used for the direct edition:

```bash
APP_STORE_VERSION=5.1.4 \
  APP_STORE_BUILD_NUMBER=10 \
  scripts/app-store-release.sh
```

The script archives the `yaprflow-AppStore` scheme, exports an App Store signed
installer to `build/app-store/5.1.4-10/`, and verifies its identity, receipt
profile, entitlements, models, notices, privacy manifest, and universal binary.
It also rejects any Sparkle setting, framework, file, or binary linkage. The
script does not upload the package; upload the verified package with Transporter
or App Store Connect. Once Apple approves and releases it, the Mac App Store
handles automatic updates for customers who installed that edition.

Website and App Store purchases are separate. Each installed edition remains on
its own update channel. Installing one edition over the other intentionally
switches the installed copy to the newly installed channel.

## License and branding

Yaprflow-owned source code in releases through version 4.0.14 and repository
revisions through commit
`0af74ab27f24933d16c004336cf63eac95c0a6b0` remains available under Apache
License 2.0. Revisions after that boundary through commit
`0153bbd696421d07cca72822c8840a028e064ebb` remain available under PolyForm
Shield 1.0.0. Later revisions are offered under PolyForm Noncommercial 1.0.0,
adopted September 19, 2026. Previously granted rights remain available under
the license attached to those historical revisions.

The current license permits noncommercial use, modification, and distribution
under its terms. Commercial use, including commercial resale, requires a
separate written license. Copyright ownership remains with Tim Moreton. See
[LICENSE](LICENSE) for the complete terms and
[COMMERCIAL-LICENSING.md](COMMERCIAL-LICENSING.md) for commercial inquiries.
Because it restricts commercial use, this is a source-available license rather
than an OSI-approved open-source license.
Yaprflow currently accepts outside code only under a prior written contributor
agreement; see [CONTRIBUTING.md](CONTRIBUTING.md).

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
