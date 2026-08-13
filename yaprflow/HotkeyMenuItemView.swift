import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var isRecording = false
    private var isShortcutHovered = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 22))
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
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

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
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
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
            titleField.stringValue = "Record"
            titleField.textColor = .labelColor
            shortcutField.stringValue = "Press keys..."
            shortcutField.textColor = .systemBlue
        } else {
            titleField.stringValue = "Record"
            titleField.textColor = .labelColor
            shortcutField.stringValue = AppState.shared.hotkey.displayString
            shortcutField.textColor = isShortcutHovered ? .systemBlue : .secondaryLabelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard shortcutHitRect.contains(convert(event.locationInWindow, from: nil)) else {
            TranscriptionController.shared.toggle()
            enclosingMenuItem?.menu?.cancelTracking()
            return
        }
        isRecording = true
        refresh()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let hovering = shortcutHitRect.contains(convert(event.locationInWindow, from: nil))
        guard hovering != isShortcutHovered else { return }
        isShortcutHovered = hovering
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isShortcutHovered = false
        refresh()
    }

    override var acceptsFirstResponder: Bool { true }

    private var shortcutHitRect: NSRect {
        shortcutField.frame.insetBy(dx: -8, dy: -4)
    }

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
