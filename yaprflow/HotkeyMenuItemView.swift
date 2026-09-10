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
    private var isCapturingShortcut = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 118, height: 28))
        bezelStyle = .rounded
        controlSize = .regular
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        toolTip = "Click, then press a shortcut with Command, Option, Control, or Shift."
        setAccessibilityLabel("Keyboard shortcut")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

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
            setAccessibilityValue(title)
        }
    }

    @objc private func beginCapture() {
        guard !isCapturingShortcut else { return }
        isCapturingShortcut = true
        GlobalHotkey.shared.unregister()
        refresh()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturingShortcut else { return false }
        return handle(event: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturingShortcut, handle(event: event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isCapturingShortcut {
            isCapturingShortcut = false
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
        AppState.shared.hotkey = newConfig
        newConfig.save()
        NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)

        isCapturingShortcut = false
        refresh()
        window?.makeFirstResponder(nil)
        return true
    }

    private func cancelCapture() {
        isCapturingShortcut = false
        restoreCurrentHotkeyRegistration()
        refresh()
        window?.makeFirstResponder(nil)
    }

    private func restoreCurrentHotkeyRegistration() {
        let current = AppState.shared.hotkey
        GlobalHotkey.shared.register(keyCode: current.keyCode, modifiers: current.modifiers)
    }
}
