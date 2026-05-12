<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow MW</h1>
  <p><strong>Private, offline dictation for macOS — Wispr Flow style.</strong></p>
  <p>Press your hotkey. Speak. Release. The text pastes itself into the focused field.</p>
</div>

---

A personal fork of [tmoreton/yaprflow](https://github.com/tmoreton/yaprflow) with the features I wanted for daily dictation. Same local-first speech pipeline (Parakeet TDT 0.6B on the Neural Engine), same Apache-2.0 license, same menubar app — plus a handful of additions:

- 📋 **Auto-paste** — synthesized ⌘V drops the transcript straight into the focused text field. Focus-race guarded (won't paste into the wrong window if you ⌘Tab away mid-recording) and bails on password fields.
- ⏯️ **Hold-to-talk OR tap-to-toggle** — pick whichever feel fits the hotkey. Hold-to-talk supports modifier chords; tap-to-toggle is one press to start, one to stop.
- ⌨️ **F-key hotkeys** — F13–F19, arrow keys, Page/Home/End are all bindable. No more "must include a modifier" guard.
- 🎵 **Start / stop chimes** — soft system sounds confirm the mic is open and closed. Togglable.
- 🪟 **Wispr-style overlay** — floating pill at the bottom-center of the screen with three audio-level bars that bounce as you speak.
- 🔒 **100% local** — audio never leaves your Mac. No accounts, no telemetry.
- ✍️ **Grammar correction** — optional on-device MLX LLM polishes transcripts before paste (inherited from upstream).
- 📝 **Summarize** — condense any transcript on demand (inherited from upstream).

## Install (build from source)

No signed releases — Apple Developer ID notarization would require their account. Build it yourself:

```bash
git clone https://github.com/M1w234/yaprflow-mw.git
cd yaprflow-mw
HF_HUB_DISABLE_XET=1 huggingface-cli download FluidInference/parakeet-tdt-0.6b-v2-coreml \
  --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" "Decoder.mlmodelc/*" \
            "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
  --local-dir Models/parakeet-tdt-0.6b-v2
./scripts/dev-build.sh
```

`dev-build.sh` does the full loop: builds Release with ad-hoc signing, replaces `/Applications/yaprflow.app`, strips Gatekeeper quarantine, and relaunches. ~3 min cold, ~30 s incremental.

**Requires macOS 14 (Sonoma) or later.**

## Enabling auto-paste

Auto-paste needs macOS Accessibility permission (so we can synthesize ⌘V):

1. Click the waveform icon in your menubar → **Auto-Paste**
2. Grant in **System Settings → Privacy & Security → Accessibility** when prompted
3. The menu row should now read "On" (instead of orange "Needs Permission")

If you ever rebuild from source, you may need to re-grant — ad-hoc signed apps get a fresh code-directory hash each build, which can invalidate the TCC entry. Quickest reset:

```bash
tccutil reset Accessibility com.tmoreton.yaprflow
```

Then click **Auto-Paste** in the menu again to re-prompt.

## What's deliberately different from upstream

- **Bundle ID is unchanged** (`com.tmoreton.yaprflow`). This means your installed app shares the same mic / AX permissions as upstream — useful if you're switching between them.
- **No notarized releases** — I can't sign on Tim's behalf. If you want a signed `.dmg`, grab the original from [tmoreton/yaprflow/releases](https://github.com/tmoreton/yaprflow/releases) and live without the additions.
- **Overlay position moved** from top-of-screen (notch-attached) to bottom-center, where Wispr Flow puts theirs.

## Credits

- All the heavy lifting (ASR pipeline, MLX integration, menubar architecture, grammar correction) is [Tim Moreton's](https://github.com/tmoreton). This fork only adds UX polish on top.
- Speech model: [FluidInference's Parakeet TDT 0.6B v2 (CoreML)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml), CC-BY-4.0.

## License

Apache 2.0, same as upstream.
