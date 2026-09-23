# Yaprflow bundle profile

Last reviewed: September 23, 2026

## Product

Yaprflow is a local-first dictation and meeting-notes app for Mac, iPhone, and
iPad. It does not require a Yaprflow account or retain raw audio.

## Supported platforms

- macOS 14 or later for dictation and meeting capture.
- macOS 26 or later on an eligible Mac for optional Apple Intelligence tools.
- iOS 17 or later on iPhone and iPad for dictation and microphone-only meeting
  capture.

The current identifiers are `com.tmoreton.yaprflow` on macOS and
`com.tmoreton.yaprflow.ios` on iOS. Keep both stable to preserve each app's
local container and store identity.

## Shared speech stack

Both platforms bundle NVIDIA Parakeet TDT 0.6B v3 Core ML and use the pinned
FluidAudio package. Parakeet automatically detects 25 supported European
languages. The bundled Silero Core ML model provides voice-activity detection.
There is no manual language selector.

Model files are pinned in `scripts/model-checksums.sha256`, validated by
`scripts/lib/model-release.sh`, copied by `scripts/copy-models.sh`, and loaded
according to `Shared/TranscriptionCore.swift`.

## Platform behavior

Mac Dictation provides a global shortcut, live preview, clipboard copy,
and local Markdown history. Mac Meeting Notes can capture microphone and system
audio and optionally create generated notes through Apple Intelligence,
OpenAI, OpenRouter, or Ollama.

iOS Dictation captures from the device microphone, copies final text,
and retains up to 50 local results. In-person Meeting uses the microphone only,
supports typed notes and templates, and stores local JSON and Markdown records.

Meeting records use the same schema on both platforms but do not sync. The
canonical feature matrix is [`../PLATFORM_CAPABILITIES.md`](../PLATFORM_CAPABILITIES.md).

## Privacy boundary

Speech recognition and voice-activity detection run on-device. Raw audio is
discarded after transcription. Transcripts, settings, vocabulary, and meeting
records stay in each app's sandbox unless the user explicitly copies, shares,
or sends text to an optional Mac AI provider. Yaprflow has no first-party
account, inference, or storage backend.

## Distribution

The `yaprflow` scheme produces the signed and notarized direct-download Mac
edition. `yaprflow-AppStore` produces the Mac App Store edition without
Sparkle. `yaprflow-iOS` produces the iPhone and iPad app. Release scripts verify
model hashes, resources, entitlements, privacy manifests, signing, and package
contents before artifacts are distributed.

## Licensing

- FluidAudio 0.13.6: Apache License 2.0.
- NVIDIA Parakeet TDT 0.6B v3 Core ML: CC BY 4.0.
- Silero VAD Core ML: MIT License.
- Sparkle 2.10.0: MIT and its bundled permissive third-party terms; used only
  by the direct-download Mac edition.

See [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) and the in-app
Acknowledgements view for the complete current inventory.

## Release checklist

- Run `swift test` and the platform smoke tests.
- Build all three Xcode schemes with model validation enabled.
- Run `scripts/app-store-release.sh` and
  `scripts/ios-app-store-release.sh` for signed store candidates.
- Reconfirm App Store privacy, age-rating, content-rights, price, and review
  metadata whenever capabilities or third-party inputs change.
- Validate microphone, background-audio, system-audio, clipboard, meeting
  persistence, export, and existing-user migration on release hardware.
