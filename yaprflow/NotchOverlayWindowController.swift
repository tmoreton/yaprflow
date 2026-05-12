import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Overlay")

@MainActor
final class NotchOverlayWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NotchOverlayWindowController()

    // Fixed window size. SwiftUI content sits inside (with its own padding
    // and rounded background) — the window's transparent backing means only
    // the SwiftUI pill is visible. 280×44 is enough for the bars + a couple
    // of lines of transcript.
    private static let initialWidth: CGFloat = 280
    private static let initialHeight: CGFloat = 44
    /// Distance from the bottom of the visible screen frame to the bottom of
    /// the overlay pill. ~40 pt clears the Dock when shown.
    private static let bottomMargin: CGFloat = 40

    convenience init() {
        let content = NotchOverlayView(state: AppState.shared)
        let host = NSHostingController(rootView: content)
        // Deliberately NOT setting `sizingOptions = [.intrinsicContentSize]`.
        // The redesigned view's body can legitimately produce a 0×0 intrinsic
        // size (when `state.status == .idle` and `displayText` is empty, the
        // Text view is removed by an `if` clause, leaving only the level bars
        // at ~15×4). When the hosting controller auto-resizes the window to
        // match that intrinsic, the window collapses to 0×0 and disappears.
        // Keep the window at its initial size; SwiftUI content centers inside.

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
        guard let window else {
            log.error("show(): window is nil")
            return
        }
        // Skip the fade-in animation for now — if anything in the
        // NSAnimationContext path is failing on this machine, we'd never
        // become visible. Setting alphaValue directly is unambiguous.
        window.alphaValue = 1
        window.orderFrontRegardless()
        let scr = window.screen?.localizedName ?? "<nil>"
        let f = window.frame
        log.info("show(): ordered front. frame=\(NSStringFromRect(f), privacy: .public) screen=\(scr, privacy: .public) alpha=\(window.alphaValue) visible=\(window.isVisible)")
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
        let y = screen.visibleFrame.minY + Self.bottomMargin
        let target = NSRect(x: x, y: y, width: w, height: h)
        if target != window.frame {
            window.setFrame(target, display: true)
        }
    }

    /// Prefer the primary (menu-bar / key-window) screen — predictable across
    /// sessions so the overlay always shows up in the same place. Falls back
    /// to the notched display, then the first available screen.
    private static func preferredScreen() -> NSScreen? {
        if let main = NSScreen.main { return main }
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first
    }
}

private final class NotchOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
