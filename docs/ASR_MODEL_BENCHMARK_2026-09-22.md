# Local ASR model benchmark — 2026-09-22

## Decision

Use Parakeet TDT 0.6B v3 as Yaprflow's default recognizer for quick dictation and
meeting transcription. Retain Nemotron only if live partial transcripts become a
requirement again. Keep Qwen3-ASR as a future challenger, especially Qwen 1.7B,
but do not replace Parakeet with the tested Qwen 0.6B ONNX export.

## Method

- Hardware: the development Apple Silicon Mac.
- Audio: the same first 100 sorted files from LibriSpeech `test-clean` and
  `test-other` for every model (200 clips, 3,968 reference words, 25.4 minutes).
- Parakeet: FluidAudio 0.13.6 Core ML implementation, matching Yaprflow's former
  integration.
- Nemotron: Yaprflow's current 1120 ms INT8 ONNX model and production feed/finalize
  settings.
- Qwen: sherpa-onnx Qwen3-ASR 0.6B INT8 export dated 2026-03-25.
- Scoring: identical lowercase, punctuation-insensitive normalization and edit
  distance across saved hypotheses from all three models.
- Timing: inference only; model loading and file decoding were excluded.

This test is an initial controlled comparison, not a substitute for a labeled
Yaprflow corpus containing microphone dictation, overlapping speakers, room echo,
names, and company vocabulary.

## Results

| Model | Clean corpus WER | Other corpus WER | Combined corpus WER | Mean clip WER | Speed | Model files |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Parakeet TDT 0.6B v3 | 2.16% | 3.41% | 2.671% (106 errors) | 3.176% | ~62x real time | 473 MB |
| Qwen3-ASR 0.6B INT8 | 1.91% | 3.60% | 2.596% (103 errors) | 3.566% | ~5.8x real time | 954 MB |
| Nemotron 3.5 streaming 0.6B INT8 | 2.93% | 5.71% | 4.057% (161 errors) | 5.184% | ~9.6x real time | 651 MB |

Parakeet and Qwen were effectively tied: Parakeet won 25 clips, Qwen won 26,
and 149 tied. Both had four clips at or above 25% WER. On the 23 clips no longer
than three seconds, Parakeet had 3.077% corpus WER versus Qwen's 5.385%, which is
particularly relevant to quick dictation.

Peak resident memory reported for one inference process was approximately 1.73 GB
for Qwen and 1.26 GB for Nemotron. The Parakeet CLI process reported 92 MB, but
Core ML can place model resources in system/accelerator services, so that number
is not directly comparable to ONNX resident memory.

At the measured throughput, two hours of audio would take roughly two minutes to
transcribe with Parakeet, 12.5 minutes with Nemotron, or 20.6 minutes with Qwen on
this machine.

## Long meetings

Do not retain an entire one-to-two-hour recording as a single in-memory sample
array. Use VAD boundaries with a maximum segment of roughly 20–30 seconds, process
segments sequentially, append timestamped text, and release each audio buffer.
This keeps memory bounded by model state plus one segment rather than meeting
duration. Preserve a small boundary overlap only when VAD does not provide a clean
speech boundary, then remove duplicate transcript overlap during the merge.

## Reproducing the local benchmark

The Swift package now includes `yaprflow-asr-benchmark`. It accepts `nemotron` or
`qwen`, a model directory, a LibriSpeech subset directory, `--max-files`, and an
optional JSON output path. Its `--rescore` and `--compare` modes apply the same
normalizer to saved hypotheses, including FluidAudio Parakeet result JSON.
