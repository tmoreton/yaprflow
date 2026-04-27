import AppKit

/// Custom menu item view for action items (Copy Transcript / Copy Summary)
/// that mirrors the icon + title geometry used by the toggle views above
/// (Streaming / Grammar / Shortcut). Standard `NSMenuItem.image` reserves a
/// checkmark column to the left of the image, so icons rendered that way sit
/// further right than the custom views' icons — converting these to a custom
/// view makes the whole menu align on a single icon column.
@MainActor
final class IconActionMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private weak var actionTarget: AnyObject?
    private let action: Selector
    private let isEnabledProvider: () -> Bool
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(
        symbolName: String,
        title: String,
        target: AnyObject,
        action: Selector,
        isEnabled: @escaping () -> Bool
    ) {
        self.actionTarget = target
        self.action = action
        self.isEnabledProvider = isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        setup(symbolName: symbolName, title: title)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func setup(symbolName: String, title: String) {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabledProvider() else { return }
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabledProvider(), let target = actionTarget else { return }
        NSApp.sendAction(action, to: target, from: self)
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Each time the menu opens, refresh enabled state and clear stale hover.
        isHovered = false
        updateAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabledProvider() {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
    }

    private func updateAppearance() {
        let enabled = isEnabledProvider()
        let textColor: NSColor
        if isHovered && enabled {
            textColor = .white
        } else if !enabled {
            textColor = .disabledControlTextColor
        } else {
            textColor = .labelColor
        }
        titleField.textColor = textColor
        iconView.contentTintColor = textColor
        needsDisplay = true
    }
}
