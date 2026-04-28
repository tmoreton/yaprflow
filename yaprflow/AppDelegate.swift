import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        _ = NotchOverlayWindowController.shared
        registerHotkey()

        // Warm the ASR + VAD models in the background so the first hotkey press
        // doesn't block on the ~30s Encoder compile. On first launch this also
        // starts downloading the encoder from GitHub Releases in parallel with
        // the onboarding flow.
        TranscriptionController.shared.preload()

        // Preload the grammar model in the background if the user has enabled
        // grammar mode (either via onboarding or from a prior session).
        if AppState.shared.grammarMode {
            GrammarController.shared.preload()
        }

        if !OnboardingWindowController.hasCompleted {
            OnboardingWindowController.shared.show()
        }

        NotificationCenter.default.addObserver(
            forName: .yaprflowHotkeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let config = AppState.shared.hotkey
                GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yaprflow")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let shortcutItem = NSMenuItem()
        shortcutItem.view = HotkeyMenuItemView()
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        let streamingItem = NSMenuItem()
        streamingItem.view = StreamingModeMenuItemView()
        streamingItem.toolTip = "Show live partials while you speak. Turn off for single-shot mode — more accurate on longer dictations, but no text appears until you stop."
        menu.addItem(streamingItem)

        let grammarItem = NSMenuItem()
        grammarItem.view = GrammarModeMenuItemView()
        grammarItem.toolTip = "Run each transcript through an on-device LLM for grammar and punctuation correction."
        menu.addItem(grammarItem)

        let launchAtLoginItem = NSMenuItem()
        launchAtLoginItem.view = LaunchAtLoginMenuItemView()
        launchAtLoginItem.toolTip = "Open Yaprflow automatically when you log in to your Mac."
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // Copy text: original first, then corrected if grammar mode was on.
        // Custom view so the icon lines up with Shortcut/Streaming/Grammar above.
        let copyItem = NSMenuItem()
        copyItem.view = IconActionMenuItemView(
            symbolName: "doc.on.clipboard",
            title: "Copy Transcript",
            target: self,
            action: #selector(copyTranscript),
            isEnabled: {
                !AppState.shared.lastTranscript.isEmpty
                    || !AppState.shared.lastOriginalTranscript.isEmpty
            }
        )
        menu.addItem(copyItem)

        // Summarize on demand
        let summarizeItem = NSMenuItem()
        summarizeItem.view = IconActionMenuItemView(
            symbolName: "text.alignleft",
            title: "Copy Summary",
            target: self,
            action: #selector(copySummary),
            isEnabled: { !AppState.shared.lastTranscript.isEmpty }
        )
        menu.addItem(summarizeItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item
    }

    /// Copies original first, then corrected if available (overwrites clipboard)
    @objc private func copyTranscript() {
        let original = AppState.shared.lastOriginalTranscript
        let corrected = AppState.shared.lastTranscript

        let pb = NSPasteboard.general
        pb.clearContents()

        // Put original first
        if !original.isEmpty {
            pb.setString(original, forType: .string)
        }

        // Overwrite with corrected if available and different
        if !corrected.isEmpty && corrected != original {
            pb.setString(corrected, forType: .string)
        }
    }

    /// Generates and copies a summary of the last transcript (on-demand)
    @objc private func copySummary() {
        let text = AppState.shared.lastTranscript
        guard !text.isEmpty else { return }

        // Show overlay and loading state
        NotchOverlayWindowController.shared.show()
        AppState.shared.status = .summarizing

        Task { @MainActor in
            do {
                let summary = try await GrammarController.shared.summarize(text: text)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summary, forType: .string)

                // Show completion
                AppState.shared.status = .copied

                // Auto-hide after delay
                try? await Task.sleep(for: .seconds(2.0))
                if AppState.shared.status == .copied {
                    AppState.shared.status = .idle
                    NotchOverlayWindowController.shared.hide()
                }
            } catch {
                // Silent fail — hide overlay
                AppState.shared.status = .idle
                NotchOverlayWindowController.shared.hide()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyTranscript) {
            return !AppState.shared.lastTranscript.isEmpty || !AppState.shared.lastOriginalTranscript.isEmpty
        }
        if menuItem.action == #selector(copySummary) {
            return !AppState.shared.lastTranscript.isEmpty
        }
        return true
    }

    private func registerHotkey() {
        GlobalHotkey.onFire = {
            Task { @MainActor in
                TranscriptionController.shared.toggle()
            }
        }
        let config = AppState.shared.hotkey
        GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
    }
}
