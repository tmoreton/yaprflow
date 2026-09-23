# Parakeet distribution review

Last reviewed: September 23, 2026

This is a release-operations record, not legal advice.

Both Yaprflow apps bundle the NVIDIA Parakeet TDT 0.6B v3 Core ML conversion
for paid distribution. Before each store submission, confirm that the intended
distribution channel remains compatible with the applicable terms and any
written permissions held in the private release records.

## Material

- Upstream model: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
- Core ML conversion: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Pinned conversion revision: `aed02740059203c4a87495924f685de3722ae9ce`
- License notice: CC BY 4.0
- Use: bundled, on-device speech recognition in paid macOS and iOS apps

## Release evidence

- Retain attribution to NVIDIA, FluidInference, the source pages, and CC BY
  4.0 in `THIRD_PARTY_NOTICES.md` and the in-app acknowledgements.
- Preserve the exact model revision and per-file hashes used for the release.
- Keep any correspondence or legal review in private release records.
- Re-review distribution rights if the model, conversion, license, store
  terms, signing controls, or purchase model changes.
