import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI finishes Transparent App Lifecycle restoration a few seconds
        // after this callback and then makes windowless apps automatically
        // terminable. Opt out after that bookkeeping so this menu-bar app keeps
        // listening for its global hotkey while idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            ProcessInfo.processInfo.disableAutomaticTermination(
                "Yaprflow must remain available for its global hotkey"
            )
        }

        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        _ = NotchOverlayWindowController.shared
        registerHotkey()

        // Models load lazily on the first hotkey press (see ensureLoaded).
        // Preloading on launch was causing CoreML to AOT-compile the encoder
        // immediately, pinning ~1.8 GB of RAM and triggering silent Jetsam
        // kills before the user ever pressed the hotkey.

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
        menu.delegate = self
        menu.autoenablesItems = false

        item.menu = menu
        self.statusItem = item
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the menu each time it opens so Copy Transcript reflects the
    /// latest state without needing manual Combine wiring into AppKit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Record row (top, custom view).
        let shortcutItem = NSMenuItem()
        shortcutItem.view = HotkeyMenuItemView()
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem()
        copyItem.view = IconActionMenuItemView(
            symbolName: "doc.on.clipboard",
            title: "Copy Transcript",
            target: self,
            action: #selector(copyTranscript),
            isEnabled: { !AppState.shared.lastTranscript.isEmpty }
        )
        menu.addItem(copyItem)

        let aiItem = NSMenuItem()
        aiItem.view = IconActionMenuItemView(
            symbolName: "sparkles",
            title: "AI Actions…",
            target: self,
            action: #selector(showAIActions),
            isEnabled: { true }
        )
        menu.addItem(aiItem)

        let historyItem = NSMenuItem()
        historyItem.view = IconActionMenuItemView(
            symbolName: "clock.arrow.circlepath",
            title: "History",
            target: self,
            action: #selector(showHistory),
            isEnabled: { true }
        )
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let footerItem = NSMenuItem()
        footerItem.view = BottomMenuActionsView(
            target: self,
            privacyAction: #selector(showPrivacy),
            quitAction: #selector(quit)
        )
        menu.addItem(footerItem)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func copyTranscript() {
        let text = AppState.shared.lastTranscript
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func showAIActions() {
        TranscriptAIWindowController.shared.show()
    }

    @objc private func showHistory() {
        HistoryWindowController.shared.show()
    }

    @objc private func showPrivacy() {
        PrivacyWindowController.shared.show()
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
