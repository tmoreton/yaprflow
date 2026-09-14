# SherpaOnnxASR

This local Swift package wraps a pinned, ASR-only build of sherpa-onnx for
Yaprflow. The native frameworks are deliberately built with
`SHERPA_ONNX_ENABLE_TTS=OFF` and
`SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF`; this keeps the binary focused on
ASR and avoids shipping the optional eSpeak-NG TTS dependency in the paid app.

- sherpa-onnx: `v1.13.8` (`11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`)
- ONNX Runtime: `1.28.2`
- Upstream Swift wrapper SHA-256:
  `a7ff8bbc35fc27017dc4f47271592054a2138b6e716c2abb5d8b5bdcbcf49ffd`
- Reviewed Yaprflow wrapper SHA-256:
  `d4731a95c3c7015f9e2f9acb024e6f1d3dfd3b1957836403b240805d9eb718a4`

Run `scripts/build-sherpa-onnx-asr.sh` to create the ignored sherpa-onnx and
ONNX Runtime native artifacts under `Artifacts/`. ONNX Runtime's pinned release
archives are checksum-verified, and the script normalizes its macOS framework
links so Xcode emits a valid static-framework bundle hook. The tracked Swift
wrapper is the pinned upstream file with one documented addition: a public
bridge to sherpa-onnx's existing per-stream option setter. Yaprflow uses that
bridge to set a selected multilingual model language code or `auto`; no native
runtime behavior is patched.
