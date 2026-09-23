# Platform capabilities

This is the source of truth for platform-specific product and release claims.
Update it whenever a target changes model, language behavior, capture scope, or
distribution. Public website, store, privacy, and acknowledgement copy must not
generalize a capability from one platform to another.

| Capability | macOS | iPhone and iPad |
| --- | --- | --- |
| Speech model | NVIDIA Parakeet TDT 0.6B v3, Core ML | NVIDIA Parakeet TDT 0.6B v3, Core ML |
| Recognition runtime | FluidAudio 0.13.6 | FluidAudio 0.13.6 |
| Language behavior | Automatic detection across 25 supported European languages; no language selector | Automatic detection across 25 supported European languages; no language selector |
| Dictation | Global shortcut, live preview, clipboard copy, and local Markdown history | In-app microphone capture, clipboard copy, and up to 50 recent local results |
| Meetings | Microphone and system audio, typed notes, templates, local JSON/Markdown records, and optional generated notes | Microphone only, typed notes, templates, and local JSON/Markdown records |
| Generated text | Apple Intelligence on supported Macs, OpenAI, OpenRouter, or Ollama | Not currently available |
| Distribution | Signed and notarized direct download; separate App Store target exists | App Store/TestFlight target |

Both platforms process speech locally, bundle their speech and voice-activity
models, and discard raw audio after transcription. Meeting records do not sync
between platforms.

The model inventory and integrity pins live in
`Shared/TranscriptionCore.swift`, `scripts/lib/model-release.sh`, and
`scripts/model-checksums.sha256`. Third-party license details live in
`THIRD_PARTY_NOTICES.md`.
