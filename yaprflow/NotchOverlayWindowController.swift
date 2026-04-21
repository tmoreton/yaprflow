import AppKit
import SwiftUI

@MainActor
final class NotchOverlayWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NotchOverlayWindowController()

    private static let initialWidth: CGFloat = 160
    private static let initialHeight: CGFloat = 44
    private static let topMargin: CGFloat = 0

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

    func show() {
        recenter()
        window?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window?.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    func windowDidResize(_ notification: Notification) {
        recenter()
    }

    private func recenter() {
        guard let window, let screen = Self.preferredScreen() else { return }
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
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first ?? NSScreen.main
    }
}

private final class NotchOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
