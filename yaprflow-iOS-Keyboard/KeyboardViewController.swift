#if os(iOS)
import SwiftUI
import UIKit
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow.keyboard", category: "VC")

/// Principal class for the keyboard extension. Hosts the SwiftUI keyboard UI
/// and brokers text insertion + URL-scheme opens to the main app.
final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let session = KeyboardSession()
    private var heightConstraint: NSLayoutConstraint?

    private let contentHeight: CGFloat = 252

    override func viewDidLoad() {
        super.viewDidLoad()

        session.insertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        session.deleteBackward = { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        }
        session.openHostApp = { [weak self] url in
            self?.openURL(url)
        }
        session.advanceToNextKeyboard = { [weak self] in
            self?.advanceToNextInputMode()
        }
        session.needsInputModeSwitchKey = needsInputModeSwitchKey

        let view = KeyboardView(session: session)
        let hosting = UIHostingController(rootView: view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        self.view.backgroundColor = .clear

        addChild(hosting)
        self.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting

        session.refreshHistory()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Every time the keyboard reappears — including when the user swipes
        // back from Yaprflow after dictating — check for a matching result.
        session.refreshHistory()
        session.refreshAfterReturn()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        if heightConstraint == nil {
            let h = view.heightAnchor.constraint(equalToConstant: contentHeight)
            h.priority = UILayoutPriority(rawValue: 999)
            h.isActive = true
            heightConstraint = h
        }
    }

    /// Open a URL from the keyboard extension. Walks the responder chain to
    /// find `UIApplication.open(_:options:completionHandler:)` since
    /// extensions don't get a direct UIApplication reference.
    private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
        // Fallback for older iOS — extensionContext.open is documented only
        // for some extension types but works from keyboards in practice.
        extensionContext?.open(url, completionHandler: nil)
    }
}
#endif
