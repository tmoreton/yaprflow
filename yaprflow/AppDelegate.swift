import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        _ = NotchOverlayWindowController.shared
        registerHotkey()

        // Warm the ASR + VAD models in the background so the first hotkey press
        // doesn't block on the ~30s Encoder compile.
        TranscriptionController.shared.preload()

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

        let redownloadItem = NSMenuItem(
            title: "Re-download speech model",
            action: #selector(redownloadModel(_:)),
            keyEquivalent: ""
        )
        redownloadItem.target = self
        menu.addItem(redownloadItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item
    }

    @objc private func redownloadModel(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Re-download speech model?"
        alert.informativeText = "This will delete the cached model (~465 MB) and download it again on the next dictation. Use this if transcription stops working or looks corrupted."
        alert.addButton(withTitle: "Re-download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        TranscriptionController.shared.clearModelCache()
        // Kick off a fresh download now so the user doesn't wait on their next hotkey press.
        TranscriptionController.shared.preload()
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
