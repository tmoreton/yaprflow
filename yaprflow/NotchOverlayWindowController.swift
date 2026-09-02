import AppKit
import OSLog
import SwiftUI

private let overlayLog = Logger(subsystem: "com.tmoreton.yaprflow", category: "DesktopPreview")

@MainActor
final class NotchOverlayWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NotchOverlayWindowController()

    private static let initialWidth: CGFloat = 160
    private static let initialHeight: CGFloat = 44
    private static let topMargin: CGFloat = 0
    private var visibilitySequence = 0

    convenience init() {
        let content = NotchOverlayView(state: AppState.shared)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]

        let window = NotchOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.initialWidth, height: Self.initialHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.alphaValue = 0

        self.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    func show(force: Bool = false) {
        guard force || AppState.shared.isDesktopPreviewEnabled else { return }
        guard let window else { return }

        visibilitySequence += 1
        let screen = Self.preferredScreen()
        recenter(on: screen)
        window.orderFrontRegardless()
        overlayLog.info(
            "Showing desktop preview on \(screen?.localizedName ?? "unknown display", privacy: .public)"
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        visibilitySequence += 1
        let sequence = visibilitySequence
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.visibilitySequence == sequence else { return }
                window.orderOut(nil)
            }
        })
    }

    func windowDidResize(_ notification: Notification) {
        recenter(on: window?.screen ?? Self.preferredScreen())
    }

    private func recenter(on screen: NSScreen?) {
        guard let window, let screen else { return }
        let w = window.frame.width
        let h = window.frame.height
        let x = screen.frame.midX - w / 2
        let y = screen.visibleFrame.maxY - h - Self.topMargin
        let target = NSRect(x: x, y: y, width: w, height: h)
        if target != window.frame {
            window.setFrame(target, display: true)
        }
    }

    private static func preferredScreen() -> NSScreen? {
        // `main` follows the display receiving keyboard events, which is the
        // right target for a global shortcut. The pointer is the fallback for
        // a menu-bar click. Always preferring a notched display could put the
        // preview on a different MacBook screen.
        if let activeScreen = NSScreen.main {
            return activeScreen
        }
        let pointerLocation = NSEvent.mouseLocation
        if let pointedScreen = NSScreen.screens.first(where: { $0.frame.contains(pointerLocation) }) {
            return pointedScreen
        }
        return NSScreen.screens.first
    }
}

private final class NotchOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
