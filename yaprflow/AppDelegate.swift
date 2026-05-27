import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var historySectionEnd: NSMenuItem? // separator below history items

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

    /// Rebuild the menu each time it opens so history items reflect the latest
    /// state without needing manual Combine wiring into AppKit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Shortcut row (top, custom view).
        let shortcutItem = NSMenuItem()
        shortcutItem.view = HotkeyMenuItemView()
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        // Up to 3 recent transcripts, each truncated. Clicking copies the full
        // text to the pasteboard.
        let history = AppState.shared.history
        if history.isEmpty {
            let placeholder = NSMenuItem()
            placeholder.view = IconActionMenuItemView(
                symbolName: "doc.on.clipboard",
                title: "No recent transcripts",
                target: self,
                action: #selector(noop),
                isEnabled: { false }
            )
            menu.addItem(placeholder)
        } else {
            for (i, text) in history.enumerated() {
                let item = NSMenuItem()
                let selector: Selector = {
                    switch i {
                    case 0: return #selector(copyHistoryAt0)
                    case 1: return #selector(copyHistoryAt1)
                    default: return #selector(copyHistoryAt2)
                    }
                }()
                item.view = IconActionMenuItemView(
                    symbolName: "doc.on.clipboard",
                    title: Self.truncate(text, max: 26),
                    target: self,
                    action: selector,
                    isEnabled: { true }
                )
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    @objc private func noop() {}

    @objc private func copyHistoryAt0() { copyHistory(index: 0) }
    @objc private func copyHistoryAt1() { copyHistory(index: 1) }
    @objc private func copyHistoryAt2() { copyHistory(index: 2) }

    private func copyHistory(index: Int) {
        let history = AppState.shared.history
        guard index < history.count else { return }
        let text = history[index]
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Single-line truncate with an ellipsis. Collapses internal newlines so a
    /// multi-line dictation fits on one menu row.
    private static func truncate(_ text: String, max: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if oneLine.count <= max { return oneLine }
        let endIndex = oneLine.index(oneLine.startIndex, offsetBy: max)
        return oneLine[..<endIndex].trimmingCharacters(in: .whitespaces) + "…"
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
