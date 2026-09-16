# Yaprflow bundle profile

> Historical App Store and bundle planning record. Current Mac distribution is
> a direct download from yaprflow.com; see the README for the active release
> process. The pricing and App Store checklists below are no longer current.

Last reviewed: September 16, 2026

## Product

**Product name:** Yaprflow

**Description:** Private, local-first voice dictation that turns speech into
clean text and can summarize, rewrite, and organize local transcripts using
Apple Intelligence, a user-supplied OpenAI or OpenRouter key, or Ollama on Mac.

Yaprflow is the voice and AI productivity application in the planned
Productivity Bundle. It remains independently useful and purchasable. It does
not require a bundle launcher, a shared account, or any other bundle
application.

## Supported Apple platforms

- **macOS 14 Sonoma or later:** primary desktop application.
- **macOS 26 or later on an eligible Mac:** required only for the optional
  Apple Intelligence summary, transformation, and transcript-metadata features.
- **iOS 17 or later on iPhone and iPad:** local dictation and a small
  recent-transcript history. A fail-closed local archive/export verifier is in
  place; its App Store Connect record and signed-device/TestFlight validation
  are not yet documented as complete.

## Versions and identifiers

| Target | Bundle identifier | Intended version | Intended build |
| --- | --- | --- | --- |
| macOS | `com.tmoreton.yaprflow` | 5.0.1 | 5 |
| iOS | `com.tmoreton.yaprflow.ios` | 1.0.0 | 2 |

These identifiers must remain stable. In particular, the macOS identifier owns
the existing sandbox container used for transcript history, vocabulary, and
preferences.

## Primary use cases

- Dictate clean text into any Mac application with a global keyboard shortcut.
- Capture spoken thoughts and copy the result for use in email, notes, and
  other productivity tools.
- Keep and browse a private local transcript archive.
- Correct names, acronyms, product terms, and preferred spellings with a local
  vocabulary.
- Summarize, rewrite, extract action items from, and otherwise transform
  transcripts on supported Macs.
- Dictate on iPhone or iPad and quickly re-copy recent transcripts.

Yaprflow does not currently retain raw recordings or capture system audio. It
should not be marketed as a meeting recorder unless those capabilities are
implemented and separately reviewed for privacy and App Store compliance.

## Core features

- On-device multilingual streaming speech recognition in 32 production-ready
  locales, using the 1120 ms chunk-size INT8 export of NVIDIA Nemotron 3.5 ASR
  Streaming 0.6B through an ASR-only sherpa-onnx build and ONNX Runtime.
  On macOS, English (United States) is the saved default; every
  production-ready locale is selectable and Automatic detection remains
  available. The current iOS source target uses Automatic detection.
- On-device Silero voice activity detection.
- Live transcription preview and automatic clipboard copy.
- Local Markdown transcript history and vocabulary replacement on macOS.
- A short, device-local recent-transcript history on iOS.
- Optional on-device summaries, rewrites, custom transformations, titles,
  topics, and descriptions through Apple's Foundation Models framework on
  supported Macs.
- Optional OpenAI, OpenRouter, and Ollama providers for Mac AI Summary. Cloud
  keys are stored in the Mac Keychain. Automatic titles with these providers
  require a separate opt-in.
- No Yaprflow account, subscription, advertising, analytics, or tracking.

## Local and private architecture

Microphone audio is processed by models bundled with the official application.
Raw audio is not retained after transcription. On macOS, transcripts,
vocabulary, preferences, and custom AI prompts remain in the application's
sandbox container. On iOS, up to three recent transcripts are kept in local app
preferences. Apple Intelligence processing uses the on-device Foundation
Models framework. Selecting OpenAI or OpenRouter sends the selected transcript
and prompt to that provider when AI Summary is run; automatic titles with a
selected external provider require a separate opt-in. Ollama requests go to
localhost, although an Ollama cloud model may use its own cloud service.

The application does not send audio, transcripts, or generated results to a
developer-operated server. The macOS target has an outbound-network sandbox
entitlement for optional AI providers. Neither target contains a first-party
backend client.

Legacy 2.x/3.x installations, and 4.x installations that used the model
fallback, can leave a roughly 400–450 MB model-only cache under
`Application Support/FluidAudio/Models` in the sandbox. Version 5 does not use
or automatically delete that cache. It is an existing-user storage migration
risk, not a runtime service dependency; validate its exact contents before any
future cleanup.

Pinned model and native-source dependencies are retrieved only while preparing
a source build. The required runtime model assets and native frameworks are
then bundled into the application; the source dependencies and in-tree Swift
package are not. Those build-time downloads are separate from application
runtime behavior.

## First-party backend and hosted-service boundary

**First-party application backend:** None.

An installed official build does not depend on a Yaprflow-hosted API, cloud
inference service, authentication service, or hosted user-data store. There is
therefore no hosted feature that needs a StoreKit-to-service entitlement
exchange. The App Store purchase itself is sufficient for official app
distribution and updates.

The following external services are outside the application runtime boundary:

- GitHub Pages hosts the public product, privacy, and support pages.
- GitHub and Hugging Face host source-build dependencies and model artifacts.
- Apple provides App Store distribution, payment processing, updates,
  notarization, and the operating-system frameworks used by the app.
- Email sent to `tim@yaprflow.com` is voluntary support communication.

Public source builds do not receive access to any paid first-party
infrastructure because no such infrastructure exists for Yaprflow.

## Product URLs

- **Marketing URL:** <https://yaprflow.com/>
- **Privacy-policy URL:** <https://yaprflow.com/privacy.html>
- **Support URL:** <https://yaprflow.com/support.html>
- **Source URL:** <https://github.com/tmoreton/yaprflow>
- **Mac App Store URL:** <https://apps.apple.com/app/id6810892725>
- **Mac App Store Apple ID:** `6810892725`

On September 11, 2026, the marketing URL returned HTTP 200 but still advertised
the legacy free/open-source download; the privacy URL returned HTTP 200 but did
not yet match the updated local policy; and the support URL and Mac App Store
URL returned HTTP 404. Deploy the updated `docs/` site, then activate and verify
customer-facing App Store links after the listing is available.

## Licensing and third-party components

Yaprflow-owned code in releases through 4.0.14 and repository revisions through
commit `0af74ab27f24933d16c004336cf63eac95c0a6b0` remains under Apache License
2.0. The 5.0.0 release line is source available under PolyForm Shield License
1.0.0 beginning September 11, 2026. See [`../LICENSE`](../LICENSE) for the
complete transition notice and current terms. Product names, icons, logos,
domains, and associated branding are addressed separately in
[`../TRADEMARKS.md`](../TRADEMARKS.md).

The repository owner confirmed on September 11, 2026 that the git author
identities Tim Moreton, Homelab, and Tim Moreton Jr are under the same ownership
and that all Yaprflow-owned code and assets are owned by the licensor. The
first-party PolyForm transition therefore has no outstanding contributor-rights
condition. This confirmation does not apply to third-party components.

Third-party components retain their original licenses. The complete notices
are in [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) and the app's
Acknowledgements view.

| Component | License | Purpose |
| --- | --- | --- |
| FluidAudio 0.13.6 (adapted VAD portions only) | Apache License 2.0 | Core ML VAD invocation and streaming endpoint logic; the package itself is not linked |
| sherpa-onnx 1.13.8 | Apache License 2.0 | Local streaming ASR runtime, built without TTS |
| ONNX Runtime 1.28.2 | MIT License | Local neural-network inference |
| Eigen 5.0.1 | MPL 2.0 and retained upstream notices | Header dependency in the sherpa-onnx native build |
| NVIDIA Nemotron 3.5 ASR Streaming 0.6B | OpenMDW-1.1 | Bundled multilingual speech recognition |
| Silero VAD Core ML model | MIT License | Bundled voice activity detection |
| Apple frameworks and system symbols | Applicable Apple agreements | Native UI, audio, Core ML, and on-device AI |

The CC BY Parakeet model, its interim Zipformer replacement, and the later
English-only Nemotron model have been removed. The current build uses the
pinned June 11, 2026, 1120 ms chunk-size INT8 sherpa-onnx export of NVIDIA
Nemotron 3.5 ASR Streaming 0.6B. The source model covers 40 locales across 35
languages. Nineteen transcription-ready and 13 broad-coverage locales work out
of the box. On macOS, Yaprflow exposes those 32 production-ready locales as
explicit choices, defaults to English (United States), and also offers
Automatic detection; the current iOS source target uses Automatic detection.
The remaining 8 adaptation-ready locales require fine-tuning and are not
advertised as supported. OpenMDW-1.1 permits dealing in
the model materials subject to its conditions and requires the license plus
applicable copyright and origin notices to be retained when redistributing.
Both apps bundle the agreement and the exact retained-origin `NOTICE.txt`. The
repository owner's September 12, 2026 selection is a recorded release decision,
not a claim that separate written opinions were received from counsel or every
upstream rightsholder. The sherpa-onnx runtime remains Apache-2.0 and ONNX
Runtime is MIT-licensed. Yaprflow uses a pinned native sherpa build with
`SHERPA_ONNX_ENABLE_TTS=OFF` and
`SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF`, so the unused diarization surface
and optional GPL eSpeak-NG/Piper TTS stack are not distributed. Release
validation checks the final executable for the excluded TTS symbols. Its
vendored upstream Swift wrapper has one local bridge to the existing per-stream
option setter so Yaprflow can provide a selected language code or
`language=auto`; the reviewed wrapper and native output hashes are pinned by
the release scripts.

## Commercial distribution

Official version 5 builds are intended for paid App Store distribution as a
US $29.00 one-time purchase. The United States is the base region, with Apple's
comparable prices configured across all 175 available regions. There is no
Yaprflow login, subscription, or in-app purchase. Apple handles ordinary
purchase entitlement and automatic updates.

Public source remains available for inspection and developer builds under the
license that applies to that version. GitHub application releases after the
commercial cutoff are source-only and do not attach signed production DMGs.
Historical DMGs may remain available when clearly identified as legacy free
releases from the Apache-licensed generation. Model-only release assets remain
available for reproducible source builds.

Yaprflow may be included in an Apple App Store multi-app bundle, but it remains
independently purchasable and has no technical dependency on the other apps.
Bundle membership and pricing are configured in App Store Connect rather than
in this repository.

## Ongoing infrastructure and commercial costs

The installed application requires no first-party runtime infrastructure, so
there is no hosted inference, account, database, file-storage, or API bill per
user.

Ongoing operational costs and external dependencies are limited to:

- Apple Developer Program participation and applicable App Store commission.
- Domain registration and support email for `yaprflow.com`.
- Public website hosting through GitHub Pages.
- Source and build-artifact hosting through GitHub and Hugging Face.
- Support time and ordinary release operations.

GitHub Pages, GitHub Releases, and Hugging Face are availability dependencies
for the website or source-build workflow, but not for an installed official
build.

## Source-build release follow-up

The immutable `models-nemotron-3.5-streaming-1120ms-v1` GitHub mirror may not
exist until
`scripts/publish-models.sh` is run from a trusted, verified checkout. Fresh
source builds safely fall back to the checksum-pinned official sherpa-onnx
export; the VAD fetch remains pinned to an exact Hugging Face revision. Every
file is hash-verified. This is a source-build availability task, not an
installed-app runtime dependency or App Store blocker. Older model release
assets remain for compatibility with historical builds.

## Paid App Store blocker checklist

- [x] **Replace the incompatible model path.** The current build uses the
  OpenMDW-1.1-licensed multilingual Nemotron 3.5 1120 ms chunk-size export and
  a pinned ASR-only sherpa-onnx build; the previous Parakeet, Zipformer, and
  English-only Nemotron weights, unused speaker diarization implementation, and
  optional GPL TTS stack are excluded from release packaging.
- [x] **Record the Nemotron redistribution terms.** The exact model hashes,
  complete OpenMDW-1.1 agreement, retained origin notice, reviewed
  source/model-card revision, exact export revision, and the repository owner's
  September 12, 2026 implementation decision are recorded. This does not
  represent a separate counsel or rightsholder opinion.
- [ ] **Complete paid-app commercial setup.** Confirm that the Account Holder
  has accepted the current Paid Apps Agreement and completed required banking
  and tax information in App Store Connect.
- [ ] **Complete Digital Services Act status.** Declare trader or non-trader
  status in App Store Connect. For EU distribution of this commercial app,
  complete Apple's verification of the public trader address, phone number,
  and email address.
- [x] **Applied the approved paid price.** On September 11, 2026, App Store
  Connect was updated to a US $29.00 one-time price with the United States as
  the base region and Apple's comparable prices across all 175 available
  regions. Apple currently groups 171 regions under Current Price and four
  regions under a price ending on September 14 because of its scheduled
  foreign-exchange or tax adjustment. The documented 4.0.14 submission was
  configured as free with automatic release, so decide whether to withdraw or
  manage that submission as the final legacy release before making 5.0.0 the
  paid generation. Anyone who acquires the free record remains entitled to
  free updates and redownloads; later repricing does not convert that existing
  customer into a paid sale.
- [ ] **Verify the live macOS listing.** The known Apple ID is `6810892725`, but
  its public App Store URL was not live at the last review. Confirm public
  availability and the support, privacy, and marketing URLs before enabling
  customer-facing purchase links.
- [ ] **Prepare iOS App Store metadata.** Confirm or create the iOS App Store
  Connect record and Apple ID, then supply its name, subtitle, description,
  keywords, screenshots, age rating, privacy answers, review notes, pricing,
  territories, support URL, privacy URL, and marketing URL. Only the macOS
  submission is currently documented. Universal purchase requires one bundle
  ID across platforms; the current macOS and iOS IDs differ. If iOS has not
  shipped or received a record, changing its identity and adding the platform
  to the macOS record may still be possible. Existing separate records cannot
  be merged, so otherwise keep separate paid records.
- [ ] **Recheck target configuration values.** Confirm the intended Release
  values are macOS 5.0.1 build 5 and iOS 1.0.0 build 2, and make any Debug versus
  Release differences intentional before archiving.
- [ ] **Run a signed upgrade test.** Install the publicly released 4.0.14
  Developer ID build, create transcript history, vocabulary entries, and
  preferences, then install the signed Mac App Store 5.0.0 build. Verify the
  existing sandbox container remains accessible and all local data survives.
  Also verify a normal update from a prior Mac App Store build when one is
  available.
- [ ] **Verify both signed Release archives.** Build, export, install, and launch
  the macOS and iOS Release configurations with the exact distribution
  profiles. Confirm the bundled models, privacy manifests, acknowledgements,
  permission prompts, and application icons are present in the exported
  products. Use `scripts/app-store-release.sh` for macOS and
  `scripts/ios-app-store-release.sh` for iOS; both validate locally and never
  upload. `IOS_ARCHIVE_ONLY=1 scripts/ios-app-store-release.sh` is available
  while the iOS App Store record or export profile is not ready.
- [ ] **Publish and verify support/privacy pages.** Confirm the committed pages
  are live over HTTPS and update the corresponding App Store Connect URLs.
- [ ] **Configure the Productivity Bundle in App Store Connect.** Do this only
  after each member app is independently purchasable, eligible, and associated
  with the correct developer account. Set the bundle price below the sum of the
  member prices but not below the highest-priced member. Bundle availability is
  the intersection of the members' territories; there is no separate bundle
  territory setting. No code-level integration is required.

No application account, central authentication service, subscription,
analytics system, or new backend is required to clear these blockers.
