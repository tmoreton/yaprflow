# Yaprflow

Menu-bar dictation app for macOS. Press ⌘T anywhere, speak, press ⌘T again — the transcript lands on your clipboard. Fully local, fully offline once installed. A floating pill under the notch shows live transcription while you talk.

- Model: [Parakeet EOU 120m (160 ms)](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) — **English-only** streaming ASR with on-the-fly end-of-utterance detection, ~5× real-time on the Apple Neural Engine. Multilingual isn't supported here: the multilingual Parakeet (`tdt-0.6b-v3`) is batch-only, so adding other languages would mean giving up word-by-word partials.
- ASR runtime: [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.13.6
- Swift 6 / SwiftUI / AppKit · 847 LOC across 10 files · **macOS 14 (Sonoma) or later**

## Install (prebuilt DMG)

Download the latest `yaprflow.dmg` from the Releases page, open it, drag Yaprflow.app to `/Applications`, and launch. Grant microphone access the first time. The model is bundled — no download at launch.

## Build from source

```bash
git clone https://github.com/tmoreton/yaprflow.git
cd yaprflow
scripts/fetch-models.sh            # ~225 MB, pulls from GitHub Release (HF fallback)
open yaprflow.xcodeproj
```

Build & run in Xcode (⌘R). The target is `yaprflow` → macOS. A build phase copies `Models/` into the app's `Resources/Models/`, so the compiled .app is fully self-contained and works offline.

## Publishing / re-publishing the model

The Parakeet bundle is hosted on the `models-v1` tag of this repo's GitHub Releases so contributors don't need HuggingFace access.

```bash
scripts/publish-models.sh          # tars Models/ and gh-release-uploads it
```

Run this once from a machine that already has `Models/` populated. Subsequent runs use `--clobber` to update the asset in place.

## Packaging a DMG

```bash
scripts/build-dmg.sh               # -> build/yaprflow.dmg
```

This archives in Release, exports the signed app, and packages a compressed DMG. For signed+notarized public releases you'll need to add your Developer ID to the script.

## How it works

| File | What |
|---|---|
| `AppDelegate.swift` | Accessory-mode NSApp, status-bar menu, wires the Carbon hotkey. |
| `GlobalHotkey.swift` | `RegisterEventHotKey` wrapper; default ⌘T, rebindable inline in the menu. |
| `HotkeyMenuItemView.swift` | Custom NSMenuItem view that records a new shortcut on click. |
| `AudioCapture.swift` | `AVAudioEngine` tap; deep-copies each buffer off the audio thread. |
| `TranscriptionController.swift` | Loads the bundled Parakeet EOU model (falls back to HF download), streams mic buffers into `StreamingEouAsrManager`, handles clipboard copy. |
| `NotchOverlayWindowController.swift` | Borderless always-on-top NSWindow pinned below the notch. |
| `NotchOverlayView.swift` | SwiftUI pill UI; trailing 400 chars of transcript rendered in a 2-line vertical scroll anchored to the bottom (safe for hour-long sessions). |
| `AppState.swift` | `ObservableObject` holding status + full transcript. |
| `HotkeyConfig.swift` | Codable key/modifier pair, UserDefaults-persisted. |
| `yaprflowApp.swift` | `@main` stub; empty `Settings` scene so `App` is satisfied. |

Model files live at `Models/parakeet-realtime-eou-120m-coreml/160ms/` at the repo root and are copied into the app's `Resources/Models/` by a build phase. `Models/` is gitignored and hosted separately in the `models-v1` GitHub Release so the repo stays small.

## License

Apache 2.0 — see `LICENSE`.

The bundled Parakeet model ships under CC-BY-4.0 via FluidInference.
