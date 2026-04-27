import AppKit
import Combine

@MainActor
final class GrammarModeMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "Grammar")
    private let stateField = NSTextField(labelWithString: "")
    private var cancellable: AnyCancellable?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        setupLayout()
        refresh()

        cancellable = AppState.shared.$grammarMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func setupLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)
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
        stateField.stringValue = AppState.shared.grammarMode ? "On" : "Off"
    }

    override func mouseDown(with event: NSEvent) {
        AppState.shared.grammarMode.toggle()
        // Kick off the model download in the background when the user flips
        // grammar on from the menu bar — otherwise the download wouldn't
        // start until their next dictation (or next app launch).
        if AppState.shared.grammarMode {
            GrammarController.shared.preload()
        }
        // refresh() fires automatically via the Combine subscription above.
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
