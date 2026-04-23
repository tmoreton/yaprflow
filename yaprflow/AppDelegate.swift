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

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript),
            keyEquivalent: ""
        )
        copyItem.target = self
        let copyIcon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        copyIcon?.isTemplate = true
        copyItem.image = copyIcon?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        )
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item
    }

    @objc private func copyLastTranscript() {
        let transcript = AppState.shared.lastTranscript
        guard !transcript.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyLastTranscript) {
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
