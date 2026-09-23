# Third-party notices

Yaprflow uses the software and model components listed below. They remain under
their respective licenses; the Yaprflow license does not replace or restrict
those terms. Both the macOS and iOS apps use this same speech stack. The exact
platform matrix is maintained in
[`PLATFORM_CAPABILITIES.md`](PLATFORM_CAPABILITIES.md), and the canonical
in-app copy is [`yaprflow/Acknowledgements.txt`](yaprflow/Acknowledgements.txt).

## FluidAudio

- Version: 0.13.6, revision `57551cd90e0bbec342766244358bcf08afb05290`
- Project: <https://github.com/FluidInference/FluidAudio>
- License: Apache License 2.0
- Use: Parakeet Core ML inference on macOS, iPhone, and iPad; adapted Core ML
  voice-activity detection and streaming hysteresis

Yaprflow links the pinned FluidAudio package and keeps a modified VAD
implementation in [`Shared/AudioProcessing.swift`](Shared/AudioProcessing.swift).
Optional diarization and TTS features are not used. The Apache License 2.0 text
is preserved in [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt), and the
modification is identified in source and in the bundled acknowledgements.

## NVIDIA Parakeet TDT 0.6B v3 Core ML model

- Source model: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
- Core ML distribution: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Core ML distribution revision: `aed02740059203c4a87495924f685de3722ae9ce`
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- License URL: <https://creativecommons.org/licenses/by/4.0/>
- Use: bundled, offline speech recognition on macOS, iPhone, and iPad
- Integrity: exact compiled-file hashes are recorded in
  [`scripts/model-checksums.sha256`](scripts/model-checksums.sha256)

Yaprflow bundles the compiled Core ML components and vocabulary without
modifying their contents. FluidInference performed the Core ML conversion from
NVIDIA's Parakeet TDT 0.6B v3 model.

## Silero VAD Core ML model

- Core ML distribution: <https://huggingface.co/FluidInference/silero-vad-coreml>
- Upstream project: <https://github.com/snakers4/silero-vad>
- Pinned revision: `724adb2158b5fa0538c528e33ba9963e977e1633`
- Copyright: 2020–present Silero Team
- License: MIT License
- Use: bundled, on-device voice activity detection
- Integrity: exact compiled-file hashes are recorded in
  [`scripts/model-checksums.sha256`](scripts/model-checksums.sha256)

The MIT license text is reproduced in the bundled acknowledgements.

## Sparkle

- Version: 2.10.0
- Project: <https://github.com/sparkle-project/Sparkle>
- License: MIT License and bundled permissive third-party licenses
- Use: updates for the direct-download macOS edition only

The complete upstream license inventory is preserved in
[`LICENSES/Sparkle-2.10.0.txt`](LICENSES/Sparkle-2.10.0.txt).

## Apple platform components

Yaprflow uses Apple-provided frameworks including AppKit, SwiftUI, UIKit,
AVFoundation, Core ML, Foundation Models, Foundation, Combine, Carbon, and
OSLog. These components are supplied by the operating system or Apple SDK and
are governed by the applicable Apple agreements.

## Project assets and website

No third-party fonts, remote JavaScript, CSS libraries, analytics SDKs, or
advertising SDKs were found. Yaprflow-owned assets are subject to
[`TRADEMARKS.md`](TRADEMARKS.md), not a third-party license.
