import AppKit
import Carbon.HIToolbox
import Combine
import OSLog
import SwiftUI
import UserNotifications

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

        // AppKit finishes its window-restoration bookkeeping after this
        // callback and enables automatic termination for windowless apps.
        // Declare support now, then opt out after that deferred pass so this
        // menu-bar app remains available for its global hotkey while idle.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        scheduleAutomaticTerminationOptOut()

        installStatusItem()
        UNUserNotificationCenter.current().delegate = self
        if !isPreviewSmokeTest {
            Telemetry.shared.beginRun()
        }
        if !isPreviewSmokeTest && !isMeetingNotesSmokeTest {
            TranscriptionController.shared.prepareSpeechRecognizer()
        }
        #if DIRECT_DISTRIBUTION
        if !isPreviewSmokeTest && !isRecordingSmokeTest && !isMeetingNotesSmokeTest {
            AppUpdater.shared.start()
        }
        #endif
        TranscriptionController.shared.prepareVoiceDetector()
        let hotkeyRegistered = registerHotkey()

        // Nemotron is warmed above so the first hotkey press avoids its ONNX
        // graph-loading cost; idle and memory-pressure paths still release it.

        if !isPreviewSmokeTest, !isMeetingNotesSmokeTest, !OnboardingWindowController.hasCompleted {
            OnboardingWindowController.shared.show()
        }

        if isPreviewSmokeTest {
            runPreviewSmokeTest()
        }


        if isMeetingNotesSmokeTest {
            MeetingNotesWindowController.show()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                let windowPassed = MeetingNotesWindowController.isVisibleForSmokeTest
                MeetingNotesWindowController.show(.workspace, selection: .allMeetings)
                try? await Task.sleep(for: .milliseconds(200))
                let workspacePassed = MeetingNotesWindowController.isVisibleForSmokeTest
                    && MeetingNotesWindowController.destinationForSmokeTest == .workspace
                    && MeetingNotesWindowController.selectionForSmokeTest == .allMeetings
                MeetingNotesWindowController.show(.settings)
                try? await Task.sleep(for: .milliseconds(200))
                let settingsPassed = MeetingNotesWindowController.isVisibleForSmokeTest
                    && MeetingNotesWindowController.destinationForSmokeTest == .settings
                MeetingNotesWindowController.show(.workspace, selection: .liveMeeting)
                let persistencePassed = MeetingStore.runPersistenceSmokeTest()
                let passed = windowPassed && workspacePassed && settingsPassed && persistencePassed
                let output = "YAPRFLOW_MEETING_NOTES_SMOKE_TEST=\(passed ? "PASS" : "FAIL") window=\(windowPassed) workspace=\(workspacePassed) settings=\(settingsPassed) persistence=\(persistencePassed)\n"
                FileHandle.standardOutput.write(Data(output.utf8))
                NSApp.terminate(nil)
            }
        }

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
                .sink { [weak self] _ in
                    self?.updateStatusItem()
                }
            self.meetingStatusCancellable = MeetingSessionController.shared.$phase
                .removeDuplicates()
                .sink { [weak self] _ in self?.updateStatusItem() }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let meetingPhase = MeetingSessionController.shared.phase
        if meetingPhase == .recording || meetingPhase == .paused {
            button.image = Self.statusItemImage(tint: meetingPhase == .paused ? .systemOrange : .systemRed)
            button.toolTip = meetingPhase == .paused ? "Yaprflow meeting capture is paused" : "Yaprflow is recording a meeting"
            button.setAccessibilityLabel(button.toolTip ?? "Yaprflow meeting capture")
            button.contentTintColor = nil
            return
        }
        if case let .preparing(message) = meetingPhase {
            button.image = Self.statusItemImage(tint: .systemOrange)
            button.toolTip = "Yaprflow Meeting Notes: \(message)"
            button.setAccessibilityLabel(button.toolTip ?? "Yaprflow is preparing Meeting Notes")
            button.contentTintColor = nil
            return
        }
        if case let .finalizing(message) = meetingPhase {
            button.image = Self.statusItemImage(tint: .systemOrange)
            button.toolTip = "Yaprflow Meeting Notes: \(message)"
            button.setAccessibilityLabel(button.toolTip ?? "Yaprflow is finalizing Meeting Notes")
            button.contentTintColor = nil
            return
        }

        let status = AppState.shared.status

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

        let quickTitle = quickDictationIsActive ? "Stop Quick Dictation" : "Quick Dictation"
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

        let historyItem = NSMenuItem()
        historyItem.view = IconActionMenuItemView(
            symbolName: "books.vertical",
            title: "Notes & Dictations",
            target: self,
            action: #selector(showNotesAndDictations),
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

    @objc private func toggleTranscription() {
        log.info("Quick Dictation menu action activated")
        TranscriptionController.shared.toggle()
    }

    @objc private func showMeetingNotes() {
        MeetingNotesWindowController.show(.workspace, selection: .liveMeeting)
    }

    @objc private func showNotesAndDictations() {
        MeetingNotesWindowController.show(.workspace)
    }

    @objc private func showSettings() {
        MeetingNotesWindowController.show(.settings)
    }

    private func registerHotkey() -> Bool {
        GlobalHotkey.onFire = {
            Task { @MainActor in
                log.info("Quick Dictation hotkey activated")
                TranscriptionController.shared.toggle()
            }
        }
        GlobalHotkey.onMeetingNotesFire = {
            Task { @MainActor in
                log.info("Meeting Notes hotkey activated")
                MeetingNotesWindowController.show(.workspace, selection: .liveMeeting)
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
                "Quick Dictation shortcut unavailable. Quit any other Yaprflow copy, then reopen the app."
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
        state.liveTranscript = ""
        state.setDesktopPreviewEnabledForSmokeTest(false)
        state.status = .preparing("Loading voice model…")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            let stayedHiddenWhenDisabled = NotchOverlayWindowController.shared.isHiddenForSmokeTest

            state.setDesktopPreviewEnabledForSmokeTest(true)
            try? await Task.sleep(for: .milliseconds(300))
            let preparingResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.liveTranscript = "This is simulated live transcript text."
            state.status = .listening
            try? await Task.sleep(for: .milliseconds(300))
            let listeningResult = NotchOverlayWindowController.shared.smokeTestDescription

            state.status = .copied
            try? await Task.sleep(for: .milliseconds(300))
            let copiedResult = NotchOverlayWindowController.shared.smokeTestDescription

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
                && hidWhenDisabled
                && reenabledResult.hasPrefix("PASS")
            let output = "YAPRFLOW_PREVIEW_SMOKE_TEST=\(succeeded ? "PASS" : "FAIL") disabled=\(stayedHiddenWhenDisabled) preparing=[\(preparingResult)] listening=[\(listeningResult)] copied=[\(copiedResult)] toggleOff=\(hidWhenDisabled) toggleOn=[\(reenabledResult)]\n"
            FileHandle.standardOutput.write(Data(output.utf8))

            state.status = .idle
            state.liveTranscript = ""
            state.setDesktopPreviewEnabledForSmokeTest(originalPreference)
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let eventID = response.notification.request.content.userInfo["calendarEventID"] as? String
        await MainActor.run {
            CalendarMeetingService.shared.refreshIfAuthorized()
            let event = eventID.flatMap { id in
                CalendarMeetingService.shared.meetings.first { $0.id == id }
            }
            MeetingNotesWindowController.show(calendarMeeting: event)
            if event != nil {
                MeetingSessionController.shared.start()
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
