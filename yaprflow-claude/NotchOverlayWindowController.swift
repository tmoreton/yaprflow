import AppKit
import SwiftUI

@MainActor
final class NotchOverlayWindowController: NSWindowController {
    static let shared = NotchOverlayWindowController()

    private static let pillWidth: CGFloat = 640
    private static let pillHeight: CGFloat = 72
    private static let topMargin: CGFloat = 4

    convenience init() {
        let content = NotchOverlayView(state: AppState.shared)
        let hosting = NSHostingController(rootView: content)

        let window = NotchOverlayWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.pillWidth, height: Self.pillHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.alphaValue = 0

        self.init(window: window)
    }

    func show() {
        positionUnderNotch()
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

    private func positionUnderNotch() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let x = frame.midX - Self.pillWidth / 2
        let y = visible.maxY - Self.pillHeight - Self.topMargin
        window.setFrame(
            NSRect(x: x, y: y, width: Self.pillWidth, height: Self.pillHeight),
            display: true
        )
    }
}

private final class NotchOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
