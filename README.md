<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow</h1>
  <p><strong>Private, offline dictation for macOS.</strong></p>
  <p>Press ⌘T. Speak. Press ⌘T. Your words are on the clipboard.</p>
</div>

---

- 🔒 **100% local** — audio never leaves your Mac
- ⚡ **Real-time** — word-by-word partials on the Neural Engine
- 🎛️ **Menu bar** — out of your way, one hotkey away
- 🆓 **Open source** — Apache 2.0, no accounts, no telemetry

## Install

Download the latest [`yaprflow.dmg`](https://github.com/tmoreton/yaprflow/releases/latest), drag Yaprflow.app to `/Applications`, launch, and grant microphone access. The speech model is bundled — no extra downloads.

**Requires macOS 14 (Sonoma) or later.**

## Build from source

```bash
git clone https://github.com/tmoreton/yaprflow.git
cd yaprflow
scripts/fetch-models.sh
open yaprflow.xcodeproj
```

## License

Apache 2.0. The bundled [Parakeet EOU](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) model ships under CC-BY-4.0 via FluidInference.
