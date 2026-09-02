import AppKit
import Combine
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusCancellable: AnyCancellable?
    private var residencyActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isPreviewSmokeTest = ProcessInfo.processInfo.arguments.contains("--smoke-test-preview")

        // A menu-bar app is useful even with no windows open. Keep a retained
        // process activity for the entire app lifetime so macOS never treats
        // the idle, windowless process as eligible for automatic termination.
        residencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Yaprflow must remain available for its global hotkey"
        )

        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        _ = NotchOverlayWindowController.shared
        let hotkeyRegistered = registerHotkey()

        // Models load lazily on the first hotkey press (see ensureLoaded).
        // Preloading on launch was causing CoreML to AOT-compile the encoder
        // immediately, pinning ~1.8 GB of RAM and triggering silent Jetsam
        // kills before the user ever pressed the hotkey.

        if !isPreviewSmokeTest, !OnboardingWindowController.hasCompleted {
            OnboardingWindowController.shared.show()
        }

        if isPreviewSmokeTest {
            runPreviewSmokeTest()
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

        if ProcessInfo.processInfo.arguments.contains("--smoke-test-recording") {
            Task { @MainActor in
                let result: RecordingSmokeTestResult
                if let menu = statusItem?.menu {
                    menuNeedsUpdate(menu)
                    result = await TranscriptionController.shared.runRecordingSmokeTest(
                        startAction: { menu.performActionForItem(at: 0) },
                        stopAction: {
                            self.menuNeedsUpdate(menu)
                            menu.performActionForItem(at: 0)
                        }
                    )
                } else {
                    result = RecordingSmokeTestResult(
                        succeeded: false,
                        message: "The status menu was unavailable."
                    )
                }
                let succeeded = hotkeyRegistered && result.succeeded
                let hotkeyMessage = hotkeyRegistered
                    ? "The global hotkey registered successfully."
                    : "The global hotkey could not be registered."
                let output = "YAPRFLOW_RECORDING_SMOKE_TEST=\(succeeded ? "PASS" : "FAIL") \(hotkeyMessage) \(result.message)\n"
                FileHandle.standardOutput.write(Data(output.utf8))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.unregister()
        if let residencyActivity {
            ProcessInfo.processInfo.endActivity(residencyActivity)
            self.residencyActivity = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        log.info("Application reopen requested; opening the status menu")
        statusItem?.button?.performClick(nil)
        return false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusItemImage()
            button.contentTintColor = nil
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        item.menu = menu
        self.statusItem = item

        statusCancellable = AppState.shared.$status
            .removeDuplicates()
            .sink { [weak self] status in
                self?.updateStatusItem(for: status)
            }
        updateStatusItem(for: AppState.shared.status)
    }

    private func updateStatusItem(for status: TranscriptionStatus) {
        guard let button = statusItem?.button else { return }

        switch status {
        case let .preparing(message):
            button.image = Self.statusItemImage(tint: .systemOrange)
            button.toolTip = "Yaprflow: \(message)"
            button.setAccessibilityLabel("Yaprflow is preparing to record: \(message)")
        case .listening:
            button.image = Self.statusItemImage(tint: .systemRed)
            button.toolTip = "Yaprflow is recording"
            button.setAccessibilityLabel("Yaprflow is recording")
        case let .error(message):
            button.image = Self.statusItemImage(tint: .systemOrange)
            button.toolTip = "Yaprflow: \(message)"
            button.setAccessibilityLabel("Yaprflow error: \(message)")
        default:
            button.image = Self.statusItemImage()
            button.toolTip = "Yaprflow"
            button.setAccessibilityLabel("Yaprflow")
        }

        // A template image can be recolored by the menu bar after
        // `contentTintColor` is applied, which made the recording state turn
        // black on some appearances. Colored states above use palette-rendered
        // non-template images, so keep AppKit's secondary tint disabled.
        button.contentTintColor = nil
    }

    private static func statusItemImage(tint: NSColor? = nil) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Yaprflow"
        ) else {
            return nil
        }

        guard let tint else {
            symbol.isTemplate = true
            return symbol
        }

        let palette = NSImage.SymbolConfiguration(paletteColors: [tint])
        let colored = symbol.withSymbolConfiguration(palette) ?? symbol
        colored.isTemplate = false
        colored.accessibilityDescription = "Yaprflow"
        return colored
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the menu each time it opens so Copy Transcript reflects the
    /// latest state without needing manual Combine wiring into AppKit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Keep the primary action native so AppKit owns the entire hit target.
        // The previous split custom row let its text fields swallow clicks.
        let transcribeItem = NSMenuItem(
            title: AppState.shared.status == .listening ? "Stop Recording" : "Transcribe",
            action: #selector(toggleTranscription),
            keyEquivalent: ""
        )
        transcribeItem.target = self
        transcribeItem.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "Transcribe"
        )
        menu.addItem(transcribeItem)

        // Shortcut editing stays separate from the recording action.
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
            title: "AI Actions",
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
            settingsAction: #selector(showSettings),
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

    @objc private func toggleTranscription() {
        log.info("Transcribe menu action activated")
        TranscriptionController.shared.toggle()
    }

    @objc private func showAIActions() {
        TranscriptAIWindowController.shared.show()
    }

    @objc private func showHistory() {
        HistoryWindowController.shared.show()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    private func registerHotkey() -> Bool {
        GlobalHotkey.onFire = {
            Task { @MainActor in
                log.info("Global hotkey activated")
                TranscriptionController.shared.toggle()
            }
        }
        let config = AppState.shared.hotkey
        let registered = GlobalHotkey.shared.register(
            keyCode: config.keyCode,
            modifiers: config.modifiers
        )
        if !registered {
            AppState.shared.status = .error(
                "Keyboard shortcut unavailable. Quit any other Yaprflow copy, then reopen the app."
            )
        }
        return registered
    }

    private func runPreviewSmokeTest() {
        let state = AppState.shared
        state.liveTranscript = ""
        state.status = .preparing("Loading transcription model…")
        NotchOverlayWindowController.shared.show(force: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            state.liveTranscript = "This is simulated live transcript text."
            state.status = .listening

            try? await Task.sleep(for: .seconds(8))
            let result = NotchOverlayWindowController.shared.smokeTestDescription
            let output = "YAPRFLOW_PREVIEW_SMOKE_TEST=\(result)\n"
            FileHandle.standardOutput.write(Data(output.utf8))
            NSApp.terminate(nil)
        }
    }
}
