import AppKit
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "LaunchAtLogin")

@MainActor
final class LaunchAtLoginMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "Launch at Login")
    private let stateField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        setupLayout()
        refresh()

        // Re-read SMAppService status whenever any menu starts tracking, so the
        // toggle reflects changes the user made in System Settings → Login Items
        // since the menu was last opened.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuWillOpen(_:)),
            name: NSMenu.didBeginTrackingNotification,
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
        iconView.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        stateField.translatesAutoresizingMaskIntoConstraints = false
        stateField.font = NSFont.menuFont(ofSize: 0)
        stateField.textColor = .secondaryLabelColor
        stateField.alignment = .right
        addSubview(stateField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            stateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stateField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            stateField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 16),
        ])
    }

    @objc private func menuWillOpen(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu === enclosingMenuItem?.menu else { return }
        refresh()
    }

    private func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            stateField.stringValue = "On"
        case .requiresApproval:
            stateField.stringValue = "Needs approval"
        default:
            stateField.stringValue = "Off"
        }
    }

    override func mouseDown(with event: NSEvent) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            log.error("Toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
