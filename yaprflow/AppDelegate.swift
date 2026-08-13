import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let vocabularyItem = NSMenuItem()
        vocabularyItem.view = IconActionMenuItemView(
            symbolName: "text.book.closed",
            title: "Vocabulary",
            target: self,
            action: #selector(openVocabularyFile),
            isEnabled: { true }
        )
        menu.addItem(vocabularyItem)

        let privacyItem = NSMenuItem()
        privacyItem.view = IconActionMenuItemView(
            symbolName: "lock.shield",
            title: "Privacy",
            target: self,
            action: #selector(showPrivacyStatus),
            isEnabled: { true }
        )
        menu.addItem(privacyItem)

        menu.addItem(NSMenuItem.separator())

        let footerItem = NSMenuItem()
        footerItem.view = BottomMenuActionsView(
            target: self,
            openFolderAction: #selector(openTranscriptsFolder),
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

    @objc private func openTranscriptsFolder() {
        do {
            let url = try AppState.shared.transcriptsDirectory()
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openVocabularyFile() {
        do {
            let url = try AppState.shared.vocabularyFileURL()
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func showPrivacyStatus() {
        let alert = NSAlert()
        alert.messageText = "Yaprflow Privacy"
        alert.informativeText = """
        Dictation mode: \(AppState.shared.dictationMode.displayName)
        Speech processing: Local Core ML models
        Accounts: None
        Telemetry: None
        Vocabulary entries: \(AppState.shared.vocabularyEntryCount())

        Transcripts are saved locally in Application Support/Yaprflow/Transcripts.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
