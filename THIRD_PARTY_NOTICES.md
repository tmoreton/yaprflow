# Third-party notices

Yaprflow 5.0.0 uses the software and model components listed below. They remain
under their respective licenses; the Yaprflow license does not replace or
restrict those terms.

The macOS application exposes the corresponding notices and license links in
Settings > Acknowledgements. Both applications bundle that notice file, the
model-specific [`scripts/model-NOTICE.txt`](scripts/model-NOTICE.txt), the exact
retained-origin [`NOTICE.txt`](NOTICE.txt), and the complete OpenMDW-1.1
agreement.
The canonical in-app acknowledgement copy is maintained in
[`yaprflow/Acknowledgements.txt`](yaprflow/Acknowledgements.txt).

## FluidAudio-derived VAD adapter

- Version: 0.13.6, revision `57551cd90e0bbec342766244358bcf08afb05290`
- Project: <https://github.com/FluidInference/FluidAudio>
- License: Apache License 2.0
- Use: adapted Core ML model invocation and streaming VAD hysteresis

Yaprflow keeps a modified, narrow implementation in
[`Shared/AudioProcessing.swift`](Shared/AudioProcessing.swift). The FluidAudio
package is not linked into either application. Its downloader, diarization,
clustering, and TTS code—and its VBx and fastcluster dependencies—are not
distributed. The Apache License 2.0 text is preserved in
[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt), and the modification is
identified both in source and in the bundled Acknowledgements file.

## sherpa-onnx ASR runtime

- Version: 1.13.8, revision `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`
- Project: <https://github.com/k2-fsa/sherpa-onnx>
- License: Apache License 2.0
- Use: local streaming speech-recognition runtime

Yaprflow builds the Apple native frameworks from the pinned source with TTS and
speaker diarization disabled (`SHERPA_ONNX_ENABLE_TTS=OFF` and
`SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF`). The optional eSpeak-NG/Piper TTS
stack is therefore not linked or distributed. The vendored Swift wrapper is
based on the pinned upstream wrapper (SHA-256
`a7ff8bbc35fc27017dc4f47271592054a2138b6e716c2abb5d8b5bdcbcf49ffd`) with one
local public bridge that passes sherpa-onnx's existing per-stream option setter
through to Yaprflow for `language=auto`; the reviewed modified wrapper is pinned
at SHA-256 `d4731a95c3c7015f9e2f9acb024e6f1d3dfd3b1957836403b240805d9eb718a4`.
The frameworks are rebuildable from these pinned inputs with
[`scripts/build-sherpa-onnx-asr.sh`](scripts/build-sherpa-onnx-asr.sh). Because
compiler/toolchain changes can alter output bytes, release validation separately
checks the reviewed outputs in `scripts/native-asr-checksums.sha256`.

The native ASR archive incorporates the following pinned sherpa-onnx build
dependencies. Their notices are reproduced in the bundled Acknowledgements:

- kaldi-native-fbank, kaldi-decoder, kaldifst, OpenFst, and
  simple-sentencepiece — Apache License 2.0. OpenFst is copyright 2005–2026
  Google LLC.
- KISS FFT, copyright 2003–2010 Mark Borgerding — BSD 3-Clause License.
- JSON for Modern C++, copyright 2013–2025 Niels Lohmann — MIT License.
- Eigen 5.0.1 — primarily Mozilla Public License 2.0, with its upstream
  Apache/BSD/MINPACK notices retained.

The exact upstream license files for those pinned build dependencies are
bundled with both applications and preserved in
[`LICENSES/SherpaOnnx-ThirdParty-v1.13.8`](LICENSES/SherpaOnnx-ThirdParty-v1.13.8).

## ONNX Runtime

- Version: 1.28.2
- Project: <https://github.com/microsoft/onnxruntime>
- License: MIT License, copyright Microsoft Corporation
- Use: local neural-network inference for sherpa-onnx

The MIT grant is reproduced in the bundled Acknowledgements. Microsoft's
complete upstream notice inventory for this pinned version is bundled with
both apps and preserved at
[`LICENSES/ONNXRuntime-ThirdPartyNotices-v1.28.2.txt`](LICENSES/ONNXRuntime-ThirdPartyNotices-v1.28.2.txt).

## NVIDIA Nemotron 3.5 ASR Streaming 0.6B model

- Source model: <https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b>
- Source model/model-card revision reviewed:
  `ea30d66debe3740a08b573244286791d423d6b3e`
- ONNX distribution: <https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11.tar.bz2>
- ONNX archive SHA-256: `adbdd5e9fef87300c37cebfcfc4f1ebe56845c860c8a760af0a1dd65ce9beed3`
- Pinned export mirror: <https://huggingface.co/csukuangfj2/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11>
- Exact export mirror revision: `cba1c96ca5ef0e8393b50584ae153a79145dc492`
- License: OpenMDW License Agreement, version 1.1
- License text source revision: `b26b32b34ad2edcc29a7707abb68dcfb25a538c1`
- License text SHA-256: `2ab44b68365473c112f5092211a38f231cb23e50de68b75a13369adbd76a74df`
- Use: bundled, on-device multilingual streaming speech recognition
- Integrity: exact compiled-file hashes are recorded in
  [`scripts/model-checksums.sha256`](scripts/model-checksums.sha256)

Yaprflow bundles the 1120 ms chunk-size INT8 encoder, decoder, joiner, and token
table without modifying their contents. The upstream model covers 40 locales
across 35 languages: 19 transcription-ready and 13 broad-coverage locales work
out of the box, while 8 adaptation-ready locales require fine-tuning. Yaprflow
exposes automatic language detection for the 32 production-ready locales. The
complete agreement is preserved at
[`LICENSES/OpenMDW-1.1.txt`](LICENSES/OpenMDW-1.1.txt) and bundled with both
applications. The applicable model origin is retained in [`NOTICE.txt`](NOTICE.txt).
The export repository does not identify the precise NVIDIA commit used for its
conversion; the export revision, official archive digest, and per-file hashes
are the authoritative binary provenance.

## Silero VAD Core ML model

- Core ML distribution: <https://huggingface.co/FluidInference/silero-vad-coreml>
- Upstream project: <https://github.com/snakers4/silero-vad>
- Pinned revision: `724adb2158b5fa0538c528e33ba9963e977e1633`
- Copyright: 2020–present Silero Team
- License: MIT License
- Use: bundled, on-device voice activity detection
- Integrity: exact compiled-file hashes are recorded in
  [`scripts/model-checksums.sha256`](scripts/model-checksums.sha256)

The MIT license text is reproduced in the bundled Acknowledgements file.

## Apple platform components

Yaprflow uses Apple-provided frameworks including AppKit, SwiftUI, UIKit,
AVFoundation, Core ML, Foundation Models, Foundation, Combine, Carbon, and
OSLog. It also renders Apple system symbols and uses system-installed fonts.
These components are provided by the operating system or Apple SDK and are
governed by the applicable Apple agreements; they are not bundled third-party
source in this repository.

## Project assets and website

No third-party fonts, remote JavaScript, CSS libraries, analytics SDKs, or
advertising SDKs were found. The Yaprflow icons, website graphics, and App Store
screenshots are project-owned assets according to the repository history and
the repository owner's September 11, 2026 ownership confirmation. They are
subject to [`TRADEMARKS.md`](TRADEMARKS.md), not a third-party license.
