import AppKit
import Combine

/// Menu row for the Auto-Paste toggle. Three visible states:
///
///   - "Off"               — disabled (default)
///   - "On"                — enabled AND Accessibility permission granted
///   - "Needs Permission"  — enabled but AX is missing/revoked; click re-prompts
///                           or opens System Settings → Privacy & Security
///
/// Why three states instead of two: TCC for Accessibility is tied to the app's
/// code signature, and ad-hoc signed builds (`dev-build.sh` every iteration)
/// can invalidate the existing grant. A two-state toggle would lie to the user
/// — saying "On" while the synthesized ⌘V is being silently dropped by the OS.
@MainActor
final class AutoPasteMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "Auto-Paste")
    private let stateField = NSTextField(labelWithString: "")
    private var cancellable: AnyCancellable?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        setupLayout()
        refresh()

        cancellable = AppState.shared.$autoPasteMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func setupLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
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

    private func refresh() {
        let enabled = AppState.shared.autoPasteMode
        if !enabled {
            stateField.stringValue = "Off"
            stateField.textColor = .secondaryLabelColor
        } else if AutoPaste.hasAccessibility {
            stateField.stringValue = "On"
            stateField.textColor = .secondaryLabelColor
        } else {
            stateField.stringValue = "Needs Permission"
            stateField.textColor = .systemOrange
        }
    }

    override func mouseDown(with event: NSEvent) {
        let enabled = AppState.shared.autoPasteMode
        let trusted = AutoPaste.hasAccessibility

        if enabled && !trusted {
            // "Needs Permission" → first try the system prompt; if that
            // returns false synchronously (user previously denied), open
            // the Accessibility pane so they can flip the switch manually.
            let nowTrusted = AutoPaste.promptForAccessibility()
            if !nowTrusted {
                AutoPaste.openAccessibilitySettings()
            }
        } else if !enabled {
            AppState.shared.autoPasteMode = true
            // Turning on for the first time — prompt for AX if we don't
            // already have it. Mirror the onboarding behaviour so users who
            // skipped the auto-paste step in onboarding still get a prompt.
            if !trusted {
                _ = AutoPaste.promptForAccessibility()
            }
        } else {
            // Was on → turn off.
            AppState.shared.autoPasteMode = false
        }

        refresh()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
