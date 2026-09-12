# Parakeet App Store clearance packet

> Historical record — the Parakeet-specific CC BY/App Store issue was resolved
> by replacement on September 11, 2026. Current Yaprflow builds do not bundle
> Parakeet. As of September 12 they use the June 11, 2026, 1120 ms chunk-size
> INT8 streaming export of multilingual NVIDIA Nemotron 3.5 ASR 0.6B under
> OpenMDW-1.1, an Apache-2.0 ASR-only sherpa-onnx build, and MIT-licensed ONNX
> Runtime. The pinned revisions, retained origin notice, license, and repository
> owner's decision are recorded in `APP_STORE_SUBMISSION.md`.

Last reviewed: September 12, 2026

This is a historical release-operations aid, not legal advice. It did not clear
the Parakeet path: do not reintroduce that model into paid App Store builds
without counsel or the relevant rightsholders confirming the exact distribution
arrangement in writing. Current Nemotron 3.5 terms are documented separately.

## Material to identify

- NVIDIA Parakeet TDT 0.6B v3 upstream model:
  <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
- FluidInference Core ML conversion:
  <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Pinned conversion revision:
  `aed02740059203c4a87495924f685de3722ae9ce`
- Current license notice: CC BY 4.0
- Intended use: bundled, on-device speech recognition in paid Yaprflow apps
  distributed through Apple's App Store

CC BY 4.0 permits commercial use, but section 2(a)(5)(B) addresses downstream
terms and effective technological measures. App Store applications are also
subject to Apple's Usage Rules, license terms, signing, and FairPlay security
controls. A separate public download of the same material is not a substitute
for permission covering the App Store copy.

Primary references:

- <https://creativecommons.org/licenses/by/4.0/legalcode>
- <https://wiki.creativecommons.org/wiki/version_4>
- <https://developer.apple.com/help/app-store-connect/reference/app-information/app-information>
- <https://developer.apple.com/support/terms/apple-developer-program-license-agreement/>

## Permission request

Send a request to NVIDIA and, conservatively, FluidInference. Adapt the legal
name and contact details before sending:

> Yaprflow plans to bundle the identified Parakeet TDT 0.6B v3 Core ML files in
> paid macOS and iOS applications distributed through Apple's App Store. The
> files will run entirely on-device and will retain prominent attribution to
> NVIDIA, FluidInference, the source pages, and CC BY 4.0.
>
> Please confirm that you are authorized to grant the relevant rights and that
> you grant Tim Moreton and Yaprflow a non-exclusive, worldwide permission to
> reproduce and distribute these exact model weights and Core ML conversion as
> part of current and future paid Yaprflow applications and updates through the
> Apple App Store. The permission must expressly allow that distribution to be
> subject to Apple's mandatory Usage Rules and application license terms,
> digital signing, FairPlay Security Solution, and other App Store technical
> controls, notwithstanding CC BY 4.0 section 2(a)(5)(B). Attribution and the
> CC BY notice will remain available in the application and documentation.
>
> Please also confirm whether this permission covers the rights of all relevant
> owners in the upstream weights and the FluidInference Core ML conversion. If
> it does not, please identify any additional party whose permission is needed.

## Evidence required before release

- A dated written grant from an authorized representative, with the granting
  entity and scope unambiguous.
- Confirmation that both the upstream weights and Core ML conversion are
  covered, or separate grants that collectively cover them.
- Express coverage of commercial Apple App Store distribution and Apple's
  contractual and technical controls.
- Permission covering app updates, not only one binary or one store version.
- Continued attribution requirements recorded in
  `yaprflow/Acknowledgements.txt` and `THIRD_PARTY_NOTICES.md`.
- Legal review of any custom App Store EULA and its third-party-material
  carve-out after the permission language is known.

Keep any original correspondence in the private release records. Record only a
non-sensitive clearance summary and its review date in this repository. If the
grant is incomplete or cannot be obtained, replace Parakeet with a model whose
terms are compatible with the intended App Store channel and rerun the privacy,
quality, size, attribution, and model-integrity reviews.
