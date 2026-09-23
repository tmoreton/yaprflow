import AppKit
import Carbon.HIToolbox
import Combine
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let automaticTerminationReason =
        "Yaprflow must remain available for its global hotkey"

    private var statusItem: NSStatusItem?
    private var statusCancellable: AnyCancellable?
    private var meetingStatusCancellable: AnyCancellable?
    private var residencyTask: Task<Void, Never>?
    private var isAutomaticTerminationDisabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let isPreviewSmokeTest = arguments.contains("--smoke-test-preview")
        let isRecordingSmokeTest = arguments.contains("--smoke-test-recording")
        let isMeetingNotesSmokeTest = arguments.contains("--smoke-test-meeting-notes")
        let isMeetingAudioSmokeTest = arguments.contains("--smoke-test-meeting-audio")
        let isEditMenuSmokeTest = arguments.contains("--smoke-test-edit-menu")
        #if DEBUG
        let isMeetingNotesPreview = arguments.contains("--preview-meeting-notes")
        let isSettingsPreview = arguments.contains("--preview-settings")
        #else
        let isMeetingNotesPreview = false
        let isSettingsPreview = false
        #endif
        let isMeetingSmokeTest = isMeetingNotesSmokeTest
            || isMeetingAudioSmokeTest
            || isMeetingNotesPreview
            || isSettingsPreview

        // AppKit finishes its window-restoration bookkeeping after this
        // callback and enables automatic termination for windowless apps.
        // Declare support now, then opt out after that deferred pass so this
        // menu-bar app remains available for its global hotkey while idle.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        scheduleAutomaticTerminationOptOut()

        installApplicationMenus()
        if isEditMenuSmokeTest {
            let passed = validateEditMenuForSmokeTest()
            let output = "YAPRFLOW_EDIT_MENU_SMOKE_TEST=\(passed ? "PASS" : "FAIL")\n"
            FileHandle.standardOutput.write(Data(output.utf8))
            NSApp.terminate(nil)
            return
        }
        installStatusItem()
        if !isPreviewSmokeTest {
            Telemetry.shared.beginRun()
        }
        if !isPreviewSmokeTest && !isMeetingSmokeTest {
            TranscriptionController.shared.prepareSpeechRecognizer()
        }
        #if DIRECT_DISTRIBUTION
        if !isPreviewSmokeTest && !isRecordingSmokeTest && !isMeetingSmokeTest {
            AppUpdater.shared.start()
        }
        #endif
        TranscriptionController.shared.prepareVoiceDetector()
        let hotkeyRegistered = registerHotkey()

        // Parakeet is warmed above so the first hotkey press avoids its Core ML
        // graph-loading cost; idle and memory-pressure paths still release it.

        if !isPreviewSmokeTest, !isMeetingSmokeTest, !OnboardingWindowController.hasCompleted {
            OnboardingWindowController.shared.show()
        }

        if isPreviewSmokeTest {
            runPreviewSmokeTest()
        }

        #if DEBUG
        if isMeetingNotesPreview {
            MeetingNotesWindowController.show()
        } else if isSettingsPreview {
            SettingsWindowController.show()
        }
        #endif


        if isMeetingNotesSmokeTest {
            MeetingNotesWindowController.show()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                let windowPassed = MeetingNotesWindowController.isVisibleForSmokeTest
                MeetingNotesWindowController.show(selection: .liveMeeting)
                try? await Task.sleep(for: .milliseconds(200))
                let workspacePassed = MeetingNotesWindowController.isVisibleForSmokeTest
                    && MeetingNotesWindowController.selectionForSmokeTest == .liveMeeting
                SettingsWindowController.show()
                try? await Task.sleep(for: .milliseconds(200))
                let settingsVisible = SettingsWindowController.isVisibleForSmokeTest
                let settingsKey = SettingsWindowController.isKeyForSmokeTest
                // Background smoke runs can be prevented from becoming key
                // when another signed Yaprflow copy is already active. Window
                // visibility is the deterministic behavior under test here.
                let settingsPassed = settingsVisible
                MeetingNotesWindowController.show(selection: .liveMeeting)
                let persistencePassed = MeetingStore.runPersistenceSmokeTest()
                let passed = windowPassed && workspacePassed && settingsPassed && persistencePassed
                let output = "YAPRFLOW_MEETING_NOTES_SMOKE_TEST=\(passed ? "PASS" : "FAIL") window=\(windowPassed) workspace=\(workspacePassed) settingsVisible=\(settingsVisible) settingsKey=\(settingsKey) persistence=\(persistencePassed)\n"
                FileHandle.standardOutput.write(Data(output.utf8))
                NSApp.terminate(nil)
            }
        }

        #if DEBUG
        if isMeetingAudioSmokeTest {
            Task { @MainActor in
                let result = await MeetingSessionController.shared.runAudioSeparationSmokeTest()
                let output = "YAPRFLOW_MEETING_AUDIO_SMOKE_TEST=\(result.succeeded ? "PASS" : "FAIL") \(result.message)\n"
                FileHandle.standardOutput.write(Data(output.utf8))
                NSApp.terminate(nil)
            }
        }
        #endif

        NotificationCenter.default.addObserver(
            forName: .yaprflowHotkeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let config = AppState.shared.hotkey
                GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
                let meetingConfig = HotkeyConfig.meetingNotesHotkey
                GlobalHotkey.shared.registerMeetingNotes(
                    keyCode: meetingConfig.keyCode,
                    modifiers: meetingConfig.modifiers
                )
            }
        }

        if isRecordingSmokeTest {
            Task { @MainActor in
                for _ in 0..<20 {
                    if statusItem?.menu != nil { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
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
        Telemetry.shared.endRun()
        GlobalHotkey.shared.unregister()
        residencyTask?.cancel()
        residencyTask = nil
        if isAutomaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination(
                Self.automaticTerminationReason
            )
            isAutomaticTerminationDisabled = false
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

    private func scheduleAutomaticTerminationOptOut() {
        residencyTask?.cancel()
        residencyTask = Task { @MainActor [weak self] in
            // AppKit's "No windows open yet" termination assertion is
            // released several seconds after applicationDidFinishLaunching.
            // Applying our independent assertion afterward prevents that
            // release from making the process automatically terminable.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }

            ProcessInfo.processInfo.disableAutomaticTermination(
                Self.automaticTerminationReason
            )
            isAutomaticTerminationDisabled = true
            residencyTask = nil
            log.info("Disabled automatic termination for menu-bar residency")
        }
    }

    /// Yaprflow manages AppKit directly instead of using SwiftUI's App scene,
    /// so macOS does not synthesize the standard responder-chain menus for us.
    /// Text fields rely on these nil-target actions for Command-X/C/V/A/Z.
    private func installApplicationMenus() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Yaprflow")
        applicationMenu.addItem(
            withTitle: "About Yaprflow",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Hide Yaprflow",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Quit Yaprflow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderMenuItem("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(
            responderMenuItem(
                "Redo",
                action: Selector(("redo:")),
                key: "z",
                modifiers: [.command, .shift]
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(responderMenuItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(responderMenuItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(
            responderMenuItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a")
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func responderMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    private func validateEditMenuForSmokeTest() -> Bool {
        guard let editMenu = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .first(where: { $0.title == "Edit" }) else { return false }

        let expected: [(title: String, key: String, action: Selector)] = [
            ("Undo", "z", Selector(("undo:"))),
            ("Redo", "z", Selector(("redo:"))),
            ("Cut", "x", #selector(NSText.cut(_:))),
            ("Copy", "c", #selector(NSText.copy(_:))),
            ("Paste", "v", #selector(NSText.paste(_:))),
            ("Select All", "a", #selector(NSText.selectAll(_:))),
        ]
        return expected.allSatisfy { expectedItem in
            editMenu.items.contains { item in
                item.title == expectedItem.title
                    && item.keyEquivalent == expectedItem.key
                    && item.action == expectedItem.action
                    && item.target == nil
                    && item.keyEquivalentModifierMask.contains(.command)
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        // Control Center hosts status items in a remote scene. Changing the
        // button or attaching its menu during that scene's initial layout can
        // make AppKit synchronously re-enter layout.
        Task { @MainActor [weak self, weak item] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, let item, self.statusItem === item else { return }

            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu

            self.statusCancellable = AppState.shared.$status
                .removeDuplicates()
                .sink { [weak self] status in
                    self?.updateStatusItem(status: status)
                }
            self.meetingStatusCancellable = MeetingSessionController.shared.$phase
                .removeDuplicates()
                .sink { [weak self] phase in
                    self?.updateStatusItem(meetingPhase: phase)
                }
        }
    }

    private func updateStatusItem(
        status updatedStatus: TranscriptionStatus? = nil,
        meetingPhase updatedMeetingPhase: MeetingSessionPhase? = nil
    ) {
        guard let button = statusItem?.button else { return }

        // @Published emits in willSet. Reading the singleton from its sink
        // sees the previous state and leaves the icon one transition behind.
        let meetingPhase = updatedMeetingPhase ?? MeetingSessionController.shared.phase
        let status = updatedStatus ?? AppState.shared.status
        button.contentTintColor = nil

        // Active capture takes priority over any other work the app may still
        // be finishing. Only genuinely paused or preparing work is yellow.
        if status == .listening {
            button.image = Self.statusItemImage(tint: .systemRed)
            button.toolTip = "Yaprflow is recording"
            button.setAccessibilityLabel("Yaprflow is recording")
            return
        }
        if meetingPhase == .recording {
            button.image = Self.statusItemImage(tint: .systemRed)
            button.toolTip = "Yaprflow is recording a meeting"
            button.setAccessibilityLabel(button.toolTip ?? "Yaprflow meeting capture")
            return
        }
        if meetingPhase == .paused {
            button.image = Self.statusItemImage(tint: .systemYellow)
            button.toolTip = "Yaprflow meeting capture is paused"
            button.setAccessibilityLabel("Yaprflow meeting capture is paused")
            return
        }
        if case let .preparing(message) = meetingPhase {
            button.image = Self.statusItemImage(tint: .systemYellow)
            button.toolTip = "Yaprflow Meeting Notes: \(message)"
            button.setAccessibilityLabel(button.toolTip ?? "Yaprflow is preparing Meeting Notes")
            return
        }
        if case let .finalizing(message) = meetingPhase {
            button.image = Self.statusItemImage(tint: .systemYellow)
            button.toolTip = "Yaprflow Meeting Notes: \(message)"
            button.setAccessibilityLabel(button.toolTip ?? "Yaprflow is finalizing Meeting Notes")
            return
        }

        switch status {
        case let .preparing(message):
            button.image = Self.statusItemImage(tint: .systemYellow)
            button.toolTip = "Yaprflow: \(message)"
            button.setAccessibilityLabel("Yaprflow is preparing to record: \(message)")
        case .listening:
            break // Handled above so recording always wins.
        case let .error(message):
            button.image = Self.statusItemImage()
            button.toolTip = "Yaprflow: \(message)"
            button.setAccessibilityLabel("Yaprflow error: \(message)")
        default:
            button.image = Self.statusItemImage()
            button.toolTip = "Yaprflow"
            button.setAccessibilityLabel("Yaprflow")
        }

        // Colored states use bitmap-rendered non-template images. Applying
        // contentTintColor to the button can recolor them unexpectedly.
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

        // Render a real colored image. AppKit may retint a symbol configuration
        // when it moves into the remote menu-bar scene, leaving the previous
        // preparation color visible after capture has started.
        let size = NSSize(width: 18, height: 18)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return symbol
        }
        bitmap.size = size
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        ) ?? symbol
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)
        configured.draw(in: rect)
        context.compositingOperation = .sourceIn
        tint.setFill()
        NSBezierPath(rect: rect).fill()
        NSGraphicsContext.restoreGraphicsState()

        let colored = NSImage(size: size)
        colored.addRepresentation(bitmap)
        colored.isTemplate = false
        colored.accessibilityDescription = "Yaprflow"
        return colored
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the menu each time it opens so the recording action reflects
    /// the latest state without needing manual Combine wiring into AppKit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let quickDictationIsActive: Bool
        switch AppState.shared.status {
        case .preparing, .listening:
            quickDictationIsActive = true
        default:
            quickDictationIsActive = false
        }

        let meetingPhase = MeetingSessionController.shared.phase
        let meetingIsCapturing = meetingPhase.isCapturing
        let meetingIsBusy: Bool
        switch meetingPhase {
        case .preparing, .finalizing:
            meetingIsBusy = true
        default:
            meetingIsBusy = false
        }

        let quickTitle = quickDictationIsActive ? "Stop Dictation" : "Dictation"
        let quickItem = NSMenuItem(
            title: quickTitle,
            action: #selector(toggleTranscription),
            keyEquivalent: ""
        )
        quickItem.target = self
        quickItem.view = CaptureModeMenuItemView(
            symbolName: quickDictationIsActive ? "stop.circle.fill" : "mic.fill",
            title: quickTitle,
            accessoryTitle: AppState.shared.hotkey.displayString,
            target: self,
            action: #selector(toggleTranscription),
            isEnabled: { !meetingIsCapturing && !meetingIsBusy }
        )
        quickItem.isEnabled = !meetingIsCapturing && !meetingIsBusy
        menu.addItem(quickItem)

        let meetingItem = NSMenuItem(
            title: "Meeting Notes",
            action: #selector(showMeetingNotes),
            keyEquivalent: ""
        )
        meetingItem.target = self
        meetingItem.view = CaptureModeMenuItemView(
            symbolName: "person.2.wave.2",
            title: "Meeting Notes",
            accessoryTitle: HotkeyConfig.meetingNotesHotkey.displayString,
            target: self,
            action: #selector(showMeetingNotes),
            isEnabled: { !quickDictationIsActive && !meetingIsBusy }
        )
        meetingItem.isEnabled = !quickDictationIsActive && !meetingIsBusy
        menu.addItem(meetingItem)

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

    @objc private func toggleTranscription() {
        log.info("Dictation menu action activated")
        TranscriptionController.shared.toggle()
    }

    @objc private func showMeetingNotes() {
        MeetingNotesWindowController.show(selection: .liveMeeting)
    }

    @objc private func showSettings() {
        SettingsWindowController.show()
    }

    private func registerHotkey() -> Bool {
        GlobalHotkey.onFire = {
            Task { @MainActor in
                log.info("Dictation hotkey activated")
                TranscriptionController.shared.toggle()
            }
        }
        GlobalHotkey.onMeetingNotesFire = {
            Task { @MainActor in
                log.info("Meeting Notes hotkey activated")
                MeetingNotesWindowController.show(selection: .liveMeeting)
            }
        }

        let config = AppState.shared.hotkey
        let quickDictationRegistered = GlobalHotkey.shared.register(
            keyCode: config.keyCode,
            modifiers: config.modifiers
        )
        let meetingConfig = HotkeyConfig.meetingNotesHotkey
        let meetingNotesRegistered = GlobalHotkey.shared.registerMeetingNotes(
            keyCode: meetingConfig.keyCode,
            modifiers: meetingConfig.modifiers
        )
        if !quickDictationRegistered {
            AppState.shared.status = .error(
                "Dictation shortcut unavailable. Quit any other Yaprflow copy, then reopen the app."
            )
        } else if !meetingNotesRegistered {
            AppState.shared.status = .error(
                "Meeting Notes shortcut ⌘M is unavailable. Quit any other Yaprflow copy, then reopen the app."
            )
        }
        return quickDictationRegistered && meetingNotesRegistered
    }

    private func runPreviewSmokeTest() {
        let state = AppState.shared
        let originalPreference = state.isDesktopPreviewEnabled
        state.audioLevel = 0
        state.setDesktopPreviewEnabledForSmokeTest(false)
        state.status = .preparing("Loading voice model…")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            let stayedHiddenWhenDisabled = NotchOverlayWindowController.shared.isHiddenForSmokeTest

            state.setDesktopPreviewEnabledForSmokeTest(true)
            try? await Task.sleep(for: .milliseconds(300))
            let preparingResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.audioLevel = 0.75
            state.status = .listening
            try? await Task.sleep(for: .milliseconds(300))
            let listeningResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.status = .copied
            try? await Task.sleep(for: .milliseconds(300))
            let copiedResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.status = .error("Audio processing fell behind; copied text may be incomplete")
            try? await Task.sleep(for: .milliseconds(300))
            let errorResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.status = .copied
            try? await Task.sleep(for: .milliseconds(300))
            let compactAgainResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.setDesktopPreviewEnabledForSmokeTest(false)
            try? await Task.sleep(for: .milliseconds(400))
            let hidWhenDisabled = NotchOverlayWindowController.shared.isHiddenForSmokeTest

            state.setDesktopPreviewEnabledForSmokeTest(true)
            try? await Task.sleep(for: .milliseconds(300))
            let reenabledResult = NotchOverlayWindowController.shared.smokeTestDescription

            let succeeded = stayedHiddenWhenDisabled
                && preparingResult.hasPrefix("PASS")
                && listeningResult.hasPrefix("PASS")
                && copiedResult.hasPrefix("PASS")
                && errorResult.hasPrefix("PASS")
                && compactAgainResult.hasPrefix("PASS")
                && hidWhenDisabled
                && reenabledResult.hasPrefix("PASS")
            let output = "YAPRFLOW_PREVIEW_SMOKE_TEST=\(succeeded ? "PASS" : "FAIL") disabled=\(stayedHiddenWhenDisabled) preparing=[\(preparingResult)] listening=[\(listeningResult)] copied=[\(copiedResult)] error=[\(errorResult)] compactAgain=[\(compactAgainResult)] toggleOff=\(hidWhenDisabled) toggleOn=[\(reenabledResult)]\n"
            FileHandle.standardOutput.write(Data(output.utf8))

            state.status = .idle
            state.audioLevel = 0
            state.setDesktopPreviewEnabledForSmokeTest(originalPreference)
            NSApp.terminate(nil)
        }
    }
}
