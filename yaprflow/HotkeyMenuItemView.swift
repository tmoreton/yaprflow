import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: NSViewRepresentable {
    let hotkey: HotkeyConfig

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        HotkeyRecorderButton()
    }

    func updateNSView(_ nsView: HotkeyRecorderButton, context: Context) {
        nsView.updateDisplayedHotkey(hotkey)
    }
}

@MainActor
final class HotkeyRecorderButton: NSButton {
    private static let defaultTooltip =
        "Click, then press a shortcut or tap Option, Command, Control, or Shift."
    private var isCapturingShortcut = false
    private var pendingModifierOnly: HotkeyConfig?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 118, height: 28))
        bezelStyle = .rounded
        controlSize = .regular
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        toolTip = Self.defaultTooltip
        setAccessibilityLabel("Keyboard shortcut")
        refresh()
    }

    required init?(coder: NSCoder) { return nil }

    func updateDisplayedHotkey(_ hotkey: HotkeyConfig) {
        guard !isCapturingShortcut else { return }
        title = hotkey.displayString
        setAccessibilityValue(hotkey.displayString)
    }

    private func refresh() {
        if isCapturingShortcut {
            title = "Press keys…"
            contentTintColor = .systemBlue
            setAccessibilityValue("Waiting for a new shortcut")
        } else {
            title = AppState.shared.hotkey.displayString
            contentTintColor = nil
            toolTip = Self.defaultTooltip
            setAccessibilityValue(title)
        }
    }

    @objc private func beginCapture() {
        guard !isCapturingShortcut else { return }
        isCapturingShortcut = true
        pendingModifierOnly = nil
        GlobalHotkey.shared.unregister()
        refresh()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturingShortcut else { return false }
        pendingModifierOnly = nil
        return handle(event: event)
    }

    override func keyDown(with event: NSEvent) {
        pendingModifierOnly = nil
        guard isCapturingShortcut, handle(event: event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturingShortcut else {
            super.flagsChanged(with: event)
            return
        }

        let keyCode = UInt32(event.keyCode)
        guard let carbonModifier = HotkeyConfig.carbonModifier(for: keyCode),
              let eventFlag = HotkeyConfig.eventModifierFlag(for: keyCode)
        else {
            pendingModifierOnly = nil
            return
        }

        let activeFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        if activeFlags.contains(eventFlag) {
            // This may be the beginning of Option-Space (or another normal
            // shortcut), so a clean release is what commits a modifier alone.
            let otherFlags = activeFlags.subtracting(eventFlag)
            pendingModifierOnly = otherFlags.isEmpty
                ? HotkeyConfig(keyCode: keyCode, modifiers: carbonModifier)
                : nil
        } else if let pendingModifierOnly,
                  pendingModifierOnly.keyCode == keyCode,
                  activeFlags.isEmpty {
            self.pendingModifierOnly = nil
            commit(pendingModifierOnly)
        } else {
            pendingModifierOnly = nil
        }
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isCapturingShortcut {
            isCapturingShortcut = false
            pendingModifierOnly = nil
            restoreCurrentHotkeyRegistration()
            refresh()
        }
        return didResign
    }

    @discardableResult
    private func handle(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) && flags.subtracting(.capsLock).isEmpty {
            cancelCapture()
            return true
        }

        var carbonMods: UInt32 = 0
        if flags.contains(.command)  { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option)   { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control)  { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift)    { carbonMods |= UInt32(shiftKey) }

        guard carbonMods != 0 else {
            return true
        }

        let newConfig = HotkeyConfig(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
        commit(newConfig)
        return true
    }

    private func commit(_ newConfig: HotkeyConfig) {
        guard newConfig != .meetingNotesHotkey else {
            NSSound.beep()
            title = "⌘M is in use"
            toolTip = "Command-M opens Meeting Notes. Choose another shortcut for Dictation."
            return
        }
        AppState.shared.hotkey = newConfig
        newConfig.save()
        if newConfig.isModifierOnly {
            InputAutomation.requestAccessibilityAccess()
        }
        NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)

        isCapturingShortcut = false
        pendingModifierOnly = nil
        refresh()
        window?.makeFirstResponder(nil)
    }

    private func cancelCapture() {
        isCapturingShortcut = false
        pendingModifierOnly = nil
        restoreCurrentHotkeyRegistration()
        refresh()
        window?.makeFirstResponder(nil)
    }

    private func restoreCurrentHotkeyRegistration() {
        let current = AppState.shared.hotkey
        GlobalHotkey.shared.register(keyCode: current.keyCode, modifiers: current.modifiers)
        let meeting = HotkeyConfig.meetingNotesHotkey
        GlobalHotkey.shared.registerMeetingNotes(
            keyCode: meeting.keyCode,
            modifiers: meeting.modifiers
        )
    }
}
