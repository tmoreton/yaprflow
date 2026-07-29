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

@MainActor
final class BottomMenuActionsView: NSView {
    private weak var actionTarget: AnyObject?
    private let openFolderAction: Selector
    private let quitAction: Selector

    init(target: AnyObject, openFolderAction: Selector, quitAction: Selector) {
        self.actionTarget = target
        self.openFolderAction = openFolderAction
        self.quitAction = quitAction
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        autoresizingMask = [.width]
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    private func setupLayout() {
        let folderButton = makeButton(
            symbolName: "folder",
            accessibilityDescription: "Open transcripts folder",
            action: #selector(openFolder)
        )
        let quitButton = makeButton(
            symbolName: "power",
            accessibilityDescription: "Quit Yaprflow",
            action: #selector(quit)
        )

        addSubview(folderButton)
        addSubview(quitButton)

        NSLayoutConstraint.activate([
            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            folderButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -6),
            folderButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeButton(
        symbolName: String,
        accessibilityDescription: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = self
        button.action = action
        button.toolTip = accessibilityDescription
        button.setAccessibilityLabel(accessibilityDescription)
        button.contentTintColor = .labelColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    @objc private func openFolder() {
        send(action: openFolderAction)
    }

    @objc private func quit() {
        send(action: quitAction)
    }

    private func send(action: Selector) {
        guard let target = actionTarget else { return }
        NSApp.sendAction(action, to: target, from: self)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
