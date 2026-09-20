# App Store submission

> Current plan: distribute the direct edition through paid checkout at
> yaprflow.com and the separate App Store edition through Apple. The App Store
> build excludes Sparkle and receives updates only through Apple.

This is the working App Store Connect copy and release checklist for Yaprflow's
commercial generation. It also preserves the state of the historical free
4.0.14 submission so that the transition is not mistaken for a retroactive
change.

Last reviewed: September 20, 2026

## Intended release records

| Platform | Bundle ID | Version | Build | App Store record |
| --- | --- | --- | --- | --- |
| macOS | `com.tmoreton.yaprflow` | 5.2.0 | 12 | Apple ID `6810892725` |
| iPhone/iPad | `com.tmoreton.yaprflow.ios` | 1.0.0 | 3 | Not yet documented |

Keep both bundle identifiers stable. In particular, changing the macOS bundle
ID would break continuity with the existing sandbox container and App Store
record.

The historical uploaded macOS 5.0.0 build 4 predates the current product.
Version 5.1.4 build 11 is the current App Store upload. It is a clean rebuild
using the flat red website icon and otherwise matches build 10.

The verified package at
`build/app-store/5.1.4-11/export/yaprflow.pkg` with SHA-256
`08de62f591e86f8ed506da199a8b97d4a6a18f80dcc21f908aace5832006af99`
was uploaded to App Store Connect on September 19, 2026. Apple reports import
status `VALID`, quality-control state `VALID_BINARY`, and audience
`APP_STORE_ELIGIBLE` for delivery
`b44274ca-af16-4b26-b801-e11703e66eb8`.
The App Store archive/export verifier passed all signing, provisioning,
entitlement, privacy-manifest, model, notice, universal-binary, and Sparkle
exclusion checks. Select build 11 in the intended TestFlight group and complete
the App Store Connect metadata, agreements, compliance, and review steps below.

### Local 5.2.0 production evidence

On September 20, 2026, the direct Mac 5.2.0 (12) build completed the full
Developer ID release path. Apple accepted and stapled the app under notary
submission `fea9723d-b70f-425d-a9f7-19efcfcdf6e7`, then accepted and stapled
the DMG under submission `05b54eb7-d400-424c-bb19-00866b87831a`. Gatekeeper
accepted `build/yaprflow-5.2.0.dmg`; its SHA-256 is
`3886a45be8247cdb4cabaa70d7456e8ddb4d48c1c8ad5d3d1ca2155776cc5e97`.
The signed app also passed the Meeting Notes persistence and Quick Dictation
capture-engine runtime smoke tests. Nothing was uploaded to a customer-facing
download location.

The 5.2.0 (12) Mac App Store archive at
`build/app-store/5.2.0-12/yaprflow.xcarchive` passed the release script's
source, model, archive, resource, architecture, privacy, entitlement, and
Sparkle-exclusion checks. Installer export is blocked only because this Mac is
missing a `Mac Installer Distribution` certificate for team `GVXC5FQ2RP`; no
5.2.0 package was produced or uploaded.

The iOS 1.0.0 (3) archives at `build/ios-app-store/1.0.0-3/` and
`build/ios-app-store/1.0.0-3-managed/` passed the signed-archive payload,
framework, entitlement, privacy, model, notice, and provisioning checks. IPA
export is blocked because the installed App Store profile does not include the
current Apple Distribution certificate and Xcode has no authenticated
Developer account from which to regenerate it. No IPA was produced or
uploaded.

## macOS product page

- **Name:** Yaprflow
- **Subtitle:** Private voice dictation
- **Primary category:** Productivity
- **Secondary category:** Utilities
- **Copyright:** 2026 Tim Moreton
- **Price:** US $29.00, paid once; no subscription or in-app purchase
- **Marketing URL:** https://yaprflow.com/
- **Support URL:** https://yaprflow.com/support.html
- **Privacy policy URL:** https://yaprflow.com/policies/#privacy
- **Keywords:** dictation,voice,text,transcription,offline,private,speech,productivity

### Draft What's New in Version 5.2.0

Yaprflow now separates Quick Dictation from Meeting Notes. Quick Dictation
turns speech into clipboard text from a global shortcut. Meeting Notes captures
microphone and Mac audio without a meeting bot, combines the local transcript
with typed notes and calendar context, and creates editable structured notes
with evidence links. This release also adds meeting templates, local meeting
search, cross-meeting questions, and a cleaner mode-first menu.

Use this text when 5.2.0 is submitted as an update to a version that reached
Ready for Distribution. App Store Connect may not show or require the field if
the pending 4.0.14 version is withdrawn before its first release.

### Description

Yaprflow is private voice dictation and optional AI productivity for your Mac.
Press Command-T, speak naturally, press Command-T again, and paste clean text
into any app.

Speech recognition runs locally through sherpa-onnx and ONNX Runtime, with
Core ML used for voice activity detection. The complete speech model is
included with Yaprflow, so audio and transcripts do not need to leave the Mac.
There is no Yaprflow account, subscription, advertising, or cross-app tracking.
Limited usage and fixed-category error telemetry is enabled by default and can
be turned off in Settings. It never includes audio, transcripts, prompts,
vocabulary, feedback messages, or a persistent device identifier.

Features:

- Start and stop dictation with a customizable global keyboard shortcut.
- See a live transcript in a compact desktop overlay.
- Choose polished or more exact transcription output.
- Automatically copy finished text to the clipboard.
- Keep a browsable local Markdown history.
- Correct names, acronyms, and preferred spellings with a local vocabulary.
- Choose among 32 production-ready dictation locales, with English (United
  States) as the default and Automatic detection available.
- Summarize, restructure, or rewrite transcripts with Apple Intelligence on
  supported Macs, your own OpenAI or OpenRouter API key, or Ollama on your Mac.
- Generate local titles, topics, and descriptions for transcript history on
  supported Macs; automatic titles with another provider require opt-in.

Yaprflow requires macOS 14 Sonoma or later. Apple Intelligence features require
a compatible Mac with Apple Intelligence enabled and macOS 26 or later.
OpenAI and OpenRouter requests send selected transcript text and prompts to
the provider. Ollama runs through its local service; Ollama cloud models may
send requests to Ollama's service.

Yaprflow never retains raw meeting recordings. On Mac, Meeting Notes can
capture microphone and system audio after the user explicitly starts a meeting
and grants both permissions. On iPhone and iPad, In-person Meeting uses only
the device microphone and cannot capture audio from another app.

## iPhone and iPad product page

- **Name:** Yaprflow
- **Subtitle:** Private voice & meeting notes
- **Primary category:** Productivity
- **Secondary category:** Utilities
- **Copyright:** 2026 Tim Moreton
- **Marketing URL:** https://yaprflow.com/
- **Support URL:** https://yaprflow.com/support.html
- **Privacy policy URL:** https://yaprflow.com/policies/#privacy
- **Keywords:** dictation,voice,transcription,meetings,notes,offline,private,speech,clipboard,productivity

### iOS description

Turn speech into useful text without sending your voice to a transcription
service. Yaprflow includes two focused modes for iPhone and iPad.

Quick Dictation is the fast path from voice to clipboard. Speak, stop, and your
finished text is ready to paste into any app. Yaprflow keeps up to 50 recent
results locally so you can recover something you dictated earlier.

In-person Meeting is a clean workspace for conversations happening around your
device. Add a title, choose a template, type notes, and capture a live local
transcript. Finished meetings are saved as JSON and Markdown in the app's local
container and can be copied or shared when you choose.

Features:

- Local speech recognition with the complete model included in the app.
- Quick voice-to-text capture with automatic clipboard copy.
- Microphone-only in-person meeting capture with typed notes and templates.
- Local meeting library with readable Markdown export.
- 32 production-ready speech locales plus Automatic detection.
- No account, subscription, advertising, or cross-app tracking.

Audio is used only while you record and is not retained. In-person Meeting
does not capture audio from calls or other apps. Records do not yet sync with
the Mac app. Yaprflow requires iOS 17 or later.

### iOS review notes

Yaprflow has no account or login. The bundled speech model can make the first
capture slower while the local recognizer initializes.

To test Quick Dictation, select Quick, tap the microphone, speak, and tap Stop.
The transcript is copied to the clipboard and appears under the clock button.

To test In-person Meeting, select Meeting, optionally enter a title and notes,
tap Start in-person meeting, speak, and tap Stop meeting. The transcript and
notes are saved locally. Tap the folder button to open the meeting library and
copy or share its Markdown representation. A title by itself does not create an
empty meeting.

The app's `audio` background mode supports an uninterrupted meeting that the
user deliberately started before locking the device or briefly switching apps.
The recording state is clearly visible when the app is foregrounded. Audio is
processed for transcription and discarded; no recording file is created. The
iOS app does not capture other-app audio.

## App privacy answers

- **Data collected:** The Mac privacy manifest now declares user content and
  usage data linked to the provider account for optional cloud AI. Reassess the
  App Store Connect answers against the selected providers and their retention
  policies before submitting a build with this feature.
- **Tracking:** No.
- **Privacy manifest:** Included in each target's application bundle.

The app processes microphone audio on-device, stores transcripts and settings
only in its sandboxed container, and does not transmit user data to the
developer. Optional Mac AI features use Apple's on-device Foundation Models
framework by default. Users can choose OpenAI or OpenRouter with their own
Keychain-stored API key, or Ollama locally; the selected transcript and prompt
are sent to a cloud provider when the user runs AI Summary, and automatic
titles with another provider require separate opt-in. Apple separately
processes App Store purchase and Apple Account
information under Apple's terms; Yaprflow does not receive payment-card data.

Reconfirm these answers in App Store Connect against the final signed binary
and the published privacy policy before every submission.

For the separate iOS record, use the conservative disclosure below unless the
final feedback flow or Apple's current questionnaire changes:

- **Audio data:** Not collected. Microphone audio is processed on-device in
  real time, is not persisted, and is not transmitted off-device.
- **User content / transcripts / meeting notes:** Not collected. These remain
  in the app container unless the user explicitly exports them.
- **Contact info — email address:** Collected only when the user voluntarily
  sends a support email; used for App Functionality (customer support), linked
  to the user's identity, and not used for tracking.
- **User content — customer support / other user content:** Collected only when
  the user voluntarily sends a support email; used for App Functionality,
  linked to the user's identity, and not used for tracking.
- **Tracking:** No.

Apple defines collection as transmitting data off-device in a way that remains
accessible beyond servicing the request. Its optional-disclosure exception for
support forms has several conditions, including prominently displaying the
user's account name with the submitted fields. The current mail-based feedback
flow should therefore use the disclosure above rather than relying on that
exception. See Apple's [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
and [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
references when entering the final answers.

## Content rights and acknowledgements

First-party rights are cleared for the commercial transition. On September 11,
2026, the repository owner confirmed that the git author identities Tim
Moreton, Homelab, and Tim Moreton Jr are under the same ownership and that all
Yaprflow-owned code and assets are owned by the licensor. This confirmation
does not alter the licenses of the third-party components below.

Answer **Yes** when asked whether the app contains or accesses third-party
content. Current bundled components are:

- A narrow VAD adapter derived from FluidAudio 0.13.6: Apache License 2.0.
  The FluidAudio package itself, VBx, fastcluster, diarization, clustering,
  downloader, and TTS implementations are not linked or distributed.
- Silero VAD: MIT License.
- sherpa-onnx: Apache License 2.0.
- NVIDIA Nemotron 3.5 ASR Streaming 0.6B: OpenMDW License Agreement, version
  1.1. Its permission grant covers dealing in the model materials, including
  commercial redistribution, subject to the agreement's conditions.
- ONNX Runtime: MIT License; its complete upstream third-party notice inventory
  is also bundled.
- sherpa-onnx native build dependencies: Apache, BSD 3-Clause, MIT, and Eigen's
  MPL 2.0 terms; exact upstream license files are bundled.

Attributions, license links, and the applicable reproduced Apache, BSD, and MIT
texts are included in the Mac Settings > Acknowledgements view and bundled as
`Acknowledgements.txt` in both targets. Both targets also bundle the complete
OpenMDW-1.1 agreement, the detailed model notice, and an exact `NOTICE.txt`
resource retaining the model's origin and pinned source/export revisions.

The previous CC BY 4.0 Parakeet model and its interim Zipformer replacement have
been removed from the current model manifest and release packaging path. The
selected model is the pinned 1120 ms chunk-size INT8 sherpa-onnx export dated
June 11, 2026 of NVIDIA Nemotron 3.5 ASR Streaming 0.6B. The upstream source
model/model-card revision reviewed is
`ea30d66debe3740a08b573244286791d423d6b3e`; the exact export mirror revision is
`cba1c96ca5ef0e8393b50584ae153a79145dc492`. The export does not identify the
precise NVIDIA commit used for conversion, so the official archive digest and
per-file hashes are the authoritative binary pins. The model covers 40 locales
across 35 languages: 32 transcribe out of the box and are exposed as explicit
language choices plus Automatic detection, while 8 adaptation-ready locales
require fine-tuning and are not a Yaprflow product claim. OpenMDW-1.1 permits
dealing in the model materials subject to its conditions and requires
redistributed copies to retain the agreement plus applicable copyright and
origin notices. Both are bundled.
This records the owner's release decision; it does not represent that counsel
or every upstream rightsholder supplied a separate written chain-of-title
opinion.

The sherpa-onnx Apple frameworks are built with TTS and speaker diarization
disabled so the optional GPL eSpeak-NG/Piper path is not distributed; release
verification rejects those symbols if they reappear. ONNX Runtime is pinned as
a checksum-verified local artifact, with the upstream macOS framework links
normalized before Xcode packaging.

## macOS review notes

Yaprflow is a menu-bar app, so it does not show a Dock icon during normal use.
No Yaprflow account, login, subscription, network service, or separate purchase
restore flow is required; Apple handles the ordinary paid-app entitlement.

To test the main flow:

1. Launch Yaprflow and grant microphone access during onboarding.
2. Open Settings and confirm Speech language defaults to English (United
   States). Choose Automatic only when testing language detection.
3. Click the waveform icon in the menu bar, or press Command-T.
4. Speak a sentence, then press Command-T again.
5. The finished text is copied to the clipboard and saved in local History.
6. Open the menu-bar item and choose History to view the saved transcript.

The complete speech model is bundled with the app; no runtime model download is
required. Yaprflow begins preparing the recognizer in the background at launch.
Recording before that finishes—or after the speech recognizer is released
following five idle minutes or memory pressure—can take longer while the local
runtimes initialize it again.

AI Summary is optional. Its default Apple Intelligence provider requires
macOS 26, a supported Mac, and Apple Intelligence enabled in System Settings.
Reviewers can also select OpenAI or OpenRouter using their own key, or an
installed Ollama model. They can evaluate core dictation without an AI provider.

## macOS 5.0.0 checklist

Repository preparation:

- [x] Preserve bundle ID `com.tmoreton.yaprflow` and team `GVXC5FQ2RP`.
- [x] Set macOS Debug and Release to version 5.0.0 build 4.
- [x] Keep App Sandbox and hardened runtime enabled.
- [x] Limit entitlements to microphone audio input.
- [x] Include the privacy manifest and acknowledgements resource.
- [x] Publishable marketing, privacy, and dedicated support pages are present in
  `docs/`.
- [x] Retire public production-DMG upload from the GitHub release script.
- [x] Add a fail-closed Mac App Store archive/export verifier that never
  uploads automatically.
- [x] Add a fail-closed iOS App Store archive/export verifier that checks the
  signed archive and exported `.ipa` but never uploads automatically.
- [x] Pin and checksum build-time speech model files.
- [x] Record the App Store copyright and 5.0.0 update copy.

External and signed-release work:

Live URL check on September 11, 2026: the marketing URL returned HTTP 200 but
still advertised the legacy free/open-source download; the privacy URL returned
HTTP 200 but did not yet match the updated local policy; and the new support URL
and App Store URL returned HTTP 404. The updated local `docs/` pages have not
been deployed by this repository change.

- [x] Replace the CC BY Parakeet, interim Zipformer, and English-only Nemotron
  models with the pinned June 11, 2026 multilingual Nemotron 3.5 1120 ms
  chunk-size INT8 export, while retaining the ASR-only sherpa-onnx build with
  optional TTS and diarization disabled.
- [x] Record Nemotron 3.5's OpenMDW-1.1 agreement, retained origin notice,
  reviewed source/model-card revision, exact export revision and hashes, and
  September 12, 2026 owner decision to implement the commercially usable
  model. No separate counsel or rightsholder opinion is represented by this
  checkbox.
- [ ] Decide whether the pending free 4.0.14 submission should be released as
  the final legacy version, withdrawn, or otherwise managed before 5.0.0.
  Anyone who acquires that free version becomes an existing customer: App Store
  updates and redownloads remain free, so changing the same record to a paid
  price later will not charge those users.
- [ ] Accept the current Paid Apps Agreement and complete banking and tax setup
  in App Store Connect.
- [ ] Declare and verify Digital Services Act trader status in App Store
  Connect. EU distribution of a commercial app requires Apple to verify and
  display the required trader address, phone number, and email address.
- [x] Applied the approved US $29.00 one-time global price in App Store Connect
  on September 11, 2026, using the United States as the base region and Apple's
  comparable prices across all 175 available regions. Apple currently groups
  171 regions under Current Price and four regions under a price ending on
  September 14 because of its scheduled foreign-exchange or tax adjustment.
- [ ] Deploy and verify `https://yaprflow.com/`, `/privacy.html`, and
  `/support.html` over HTTPS.
- [ ] Verify the public App Store URL and replace or defer customer-facing links
  if Apple ID `6810892725` is not yet live.
- [ ] Recapture `AppStore/Assets/settings-window.png` with the speech-language
  selector, then regenerate and review the four 2560 × 1600 Mac screenshots.
- [ ] Reconfirm App Privacy, age rating, third-party-content, encryption, and
  microphone-usage answers in App Store Connect.
- [x] Re-ran `scripts/app-store-release.sh` for 5.0.0 (4) on September 12, 2026,
  after the Nemotron implementation. The script passed all 21 tests and its
  model, archive, installer, signature, entitlement, and profile checks. The
  verified package SHA-256 is
  `e7ec2910e7d9678bc0b77fc4067f78ad11f229f0f0cbb3e5c811625e782e9bd2`.
- [x] Re-ran Xcode automatic distribution signing archive/export preflight for
  the Nemotron build and verified the installer plus nested
  application/framework signatures. The current Mac Team Store profile expires
  December 19, 2026.
- [ ] If build 4 is rejected or another binary is uploaded for version 5.0.0,
  increment `CURRENT_PROJECT_VERSION`; App Store Connect will not accept a
  reused build number.
- [x] Uploaded build 5.0.0 (4) to App Store Connect on September 12, 2026.
  Delivery `f00c618c-7303-4a96-b05c-d47d10ed1a3b` completed processing with
  binary state Validated and was added to the Internal TestFlight group.
- [ ] Upload an incremented build containing the persisted speech-language
  selector; build 4 remains the earlier Automatic-only implementation.
- [ ] Install the incremented selector build through TestFlight and perform the
  release smoke test before App Review submission.
- [x] Run `scripts/ios-app-store-release.sh` for iOS 1.0.0 (3) and verify the
  signed archive. The archive passed on September 20, 2026.
- [ ] Sign in to the `GVXC5FQ2RP` Apple Developer account in Xcode, regenerate
  the iOS App Store profile so it includes the installed Apple Distribution
  certificate, rerun the script to verify the exported `.ipa`, and upload only
  after the App Store relationship and metadata decisions below are complete.
- [ ] Run the signed existing-user migration test described below.

## iPhone and iPad readiness

The source target is now internally consistent at version 1.0.0 build 3. Its
Info.plist derives version/build from Xcode settings, includes iPad
orientations, and declares its microphone purpose. Its app icon is opaque, and
the target now bundles a privacy manifest plus third-party acknowledgements.

The iOS release exposes two explicit modes. Quick Dictation copies local
speech-to-text results to the clipboard and retains up to 50 recent results.
In-person Meeting uses only the device microphone, accepts typed notes and a
shared template, and saves local JSON plus Markdown using the same
`MeetingRecord` schema as Mac. It does not capture other-app audio or run Mac AI
providers, and there is no cross-device sync in 1.0.

Distribution is not yet ready until these external steps are complete:

- [ ] Decide whether iOS is an independent paid app, part of a universal
  purchase, or a separately purchasable bundle member before changing any App
  Store relationship. A universal-purchase record requires the same bundle ID
  on every platform; the current IDs (`com.tmoreton.yaprflow` and
  `com.tmoreton.yaprflow.ios`) therefore cannot form one without changing the
  iOS identity and adding iOS to the macOS record. Separate existing app records
  cannot later be merged. Only change the currently unshipped iOS identity if
  universal purchase is the chosen model and App Store Connect confirms it is
  still safe to do so.
- [ ] Confirm or create the App Store Connect record and obtain its Apple ID.
- [x] Prepare local iPhone and iPad screenshots, product-page copy, review
  notes, and draft privacy answers. Final captures are in
  `AppStore/Screenshots/iOS/`; review them once more on the release build.
- [ ] Enter and reconfirm the iOS age rating, privacy answers, territories, and
  price in App Store Connect after the record/purchase relationship is chosen.
- [ ] Run `scripts/ios-app-store-release.sh` to create and inspect the signed
  iOS distribution archive and exported `.ipa`, then validate it on a real
  device or through TestFlight, including microphone behavior and the declared
  background-audio behavior. The script performs local verification only and
  never uploads.
- [x] Retain the `audio` background mode for uninterrupted, explicitly started
  in-person meetings. Validate its behavior on a physical device and explain
  the user-facing behavior in the review notes above.

## Existing-user migration test

The macOS app continues to use bundle ID `com.tmoreton.yaprflow`, the same team,
and the same sandbox-relative storage locations:

- `Application Support/Yaprflow/Transcripts`
- `Application Support/Yaprflow/Vocabulary.md`
- `UserDefaults` domain `com.tmoreton.yaprflow`

No database, App Group, iCloud container, Keychain migration, or raw-recording
store was found. The source-level storage paths are therefore compatible, and
the saved dictation-mode preference is no longer overwritten at launch.

Older 2.x/3.x builds, and a 4.x build that ever populated its fallback cache,
may leave a model-only directory under
`Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` or
`parakeet-tdt-0.6b-v3` inside the same sandbox. Version 5 reads its model from
the app bundle and does not use or remove those roughly 400–450 MB legacy
caches. Treat this as an orphaned-storage risk, not user data to delete during
the commercial transition. Any future one-time cleanup must first validate the
exact sandbox path and prove that it contains only replaceable model files.

Before releasing, verify the signature transition empirically:

1. In separate clean test users or virtual machines, install representative
   public Developer ID builds from the download-based generation (at least
   3.0.0) and the final legacy generation (4.0.14).
2. Create transcript history, vocabulary entries, shortcut/settings changes,
   and an AI prompt.
3. Replace the app with the signed Mac App Store 5.0.0 build without deleting
   its container.
4. Confirm every local item remains readable and new transcripts append
   normally.
5. Confirm legacy model caches neither block the upgrade nor get mistaken for
   transcript data; record their post-upgrade disk usage.
6. Separately test a normal update from any prior Mac App Store build that
   becomes available.

Do not promise migration completion until this signed-build test passes.

## GitHub and source releases

Official production binaries are distributed through the App Store. The
release script's `--publish-source` option may create an annotated tag and a
source-only GitHub release, but it does not upload the locally built DMG. The
former `--publish` option fails closed.

Existing public DMGs remain historical Apache-2.0 releases and do not need to
be deleted. Add permanent notice links to legacy release descriptions when
practical; do not silently replace previously published signed artifacts.

## Historical free 4.0.14 record

The following documents what was already submitted. It is not the commercial
5.0.0 configuration.

- **Version/build:** 4.0.14 (1)
- **Price:** Free
- **Submitted:** September 10, 2026 at 10:30 PM EDT
- **Submission ID:** `802b609b-16bf-404e-a39f-fd9b08f41e24`
- **Status when last reviewed:** Waiting for Review
- **Release setting:** Automatically after approval
- **Package:** `AppStore/Builds/Yaprflow-4.0.14-build-1.pkg`
- **Screenshots:** Four 2560 × 1600 RGB PNGs in `AppStore/Screenshots`

Completed work recorded for that submission included the app record, bundle ID,
signing assets, uploaded build, screenshots, reviewer contact, product copy,
App Privacy as Data Not Collected, 4+ age rating, microphone explanation, and
third-party-content declaration. Recheck the live App Store Connect state
before making any decision based on this snapshot.

## Productivity Bundle checklist

- [ ] Make every constituent app paid and independently available.
- [ ] Wait until every constituent app is Ready for Distribution.
- [ ] Choose a bundle price below the sum of the member-app prices but not below
  the highest-priced member. A bundle has no separate territory setting: it is
  available only in territories shared by every member app, so align the
  individual apps' availability first.
- [ ] Create the multi-app bundle only after the individual records are ready.

No launcher, shared Yaprflow account, subscription, central authentication
service, or code-level dependency on the other products is required.
