<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow</h1>
  <p><strong>Private, offline dictation for macOS.</strong></p>
  <p>Press ⌘T. Speak. Press ⌘T. Your words are on the clipboard.</p>
</div>

---

- 🔒 **100% local** — audio never leaves your Mac
- ⚡ **Accurate** — NVIDIA Parakeet TDT 0.6B on the Neural Engine, with live partials
- ✍️ **Grammar correction** — optional on-device AI polishes your transcripts
- 📝 **Summarize** — condense any transcript into a concise paragraph
- 🎛️ **Menu bar** — out of your way, one hotkey away
- 🆓 **Open source** — Apache 2.0, no accounts, no telemetry

## Install

Download the latest [`yaprflow.dmg`](https://github.com/tmoreton/yaprflow/releases/latest), drag Yaprflow.app to `/Applications`, launch, and grant microphone access. The speech model downloads automatically on first launch; grammar correction requires a one-time optional model download.

**Requires macOS 14 (Sonoma) or later.**

## Build from source

```bash
git clone https://github.com/tmoreton/yaprflow.git
cd yaprflow
scripts/fetch-models.sh
open yaprflow.xcodeproj
```

## License

Apache 2.0. The bundled [Parakeet TDT 0.6B v2](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) model ships under CC-BY-4.0 via FluidInference.
