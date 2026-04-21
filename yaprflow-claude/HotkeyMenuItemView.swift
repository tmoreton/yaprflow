import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var isRecording = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
        autoresizingMask = [.width]
        setupLayout()
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onHotkeyChanged),
            name: .yaprflowHotkeyChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func setupLayout() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.font = NSFont.menuFont(ofSize: 0)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .right
        addSubview(shortcutField)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            shortcutField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 16),
        ])
    }

    @objc private func onHotkeyChanged() {
        refresh()
    }

    private func refresh() {
        if isRecording {
            titleField.stringValue = "Press a shortcut…"
            titleField.textColor = .systemBlue
            shortcutField.stringValue = "esc"
        } else {
            titleField.stringValue = "Shortcut"
            titleField.textColor = .labelColor
            shortcutField.stringValue = AppState.shared.hotkey.displayString
        }
    }

    override func mouseDown(with event: NSEvent) {
        isRecording.toggle()
        refresh()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return handle(event: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event: event) else {
            super.keyDown(with: event)
            return
        }
    }

    @discardableResult
    private func handle(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) && flags.subtracting(.capsLock).isEmpty {
            isRecording = false
            refresh()
            enclosingMenuItem?.menu?.cancelTracking()
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

        isRecording = false
        refresh()
        enclosingMenuItem?.menu?.cancelTracking()
        return true
    }
}
