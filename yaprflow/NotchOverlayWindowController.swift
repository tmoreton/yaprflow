import AppKit
import Combine
import OSLog
import SwiftUI

private let overlayLog = Logger(subsystem: "com.tmoreton.yaprflow", category: "DesktopPreview")

@MainActor
final class NotchOverlayWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NotchOverlayWindowController()

    private static let previewWidth: CGFloat = 520
    private static let previewHeight: CGFloat = 68
    private static let topMargin: CGFloat = 8
    private var visibilitySequence = 0
    private var stateCancellable: AnyCancellable?

    convenience init() {
        let content = NotchOverlayView(state: AppState.shared)
        let host = NSHostingController(rootView: content)

        let window = NotchOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.previewWidth, height: Self.previewHeight),
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
        // NSHostingController can report a zero intrinsic size while the
        // preview state is idle. Keep a deterministic content size so the
        // first loading/listening update cannot leave an invisible 0×0 panel.
        window.setContentSize(NSSize(width: Self.previewWidth, height: Self.previewHeight))
        window.delegate = self

        // Treat visibility as derived state instead of relying on a single
        // `show()` call at recording startup. This also makes changing the
        // setting take effect immediately during an active transcription.
        stateCancellable = AppState.shared.$status
            .combineLatest(AppState.shared.$isDesktopPreviewEnabled)
            .removeDuplicates { previous, current in
                previous.0 == current.0 && previous.1 == current.1
            }
            .sink { [weak self] status, isEnabled in
                self?.synchronizeVisibility(status: status, isEnabled: isEnabled)
            }
    }

    required init?(coder: NSCoder) { fatalError() }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    func show(force: Bool = false) {
        guard force || AppState.shared.isDesktopPreviewEnabled else { return }
        guard let window else { return }

        visibilitySequence += 1
        let sequence = visibilitySequence
        let screen = Self.preferredScreen()
        prepareForDisplay(window)
        recenter(on: screen)
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.displayIfNeeded()
        overlayLog.info(
            "Showing desktop preview on \(screen?.localizedName ?? "unknown display", privacy: .public), frame \(NSStringFromRect(window.frame), privacy: .public)"
        )

        // SwiftUI performs its first layout on the next run-loop pass. Reapply
        // the fixed size and ordering afterward so AppKit cannot resize or
        // order out a just-created accessory window during that layout.
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self,
                  let window,
                  self.visibilitySequence == sequence,
                  force || AppState.shared.isDesktopPreviewEnabled
            else { return }
            self.prepareForDisplay(window)
            self.recenter(on: screen ?? Self.preferredScreen())
            window.alphaValue = 1
            window.orderFrontRegardless()
            window.displayIfNeeded()
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

    var smokeTestDescription: String {
        guard let window else { return "FAIL window=missing" }
        let intersectsDisplay = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        let hasUsableSize = window.frame.width >= 500 && window.frame.height >= 60
        let contentHasUsableSize = (window.contentView?.bounds.width ?? 0) >= 500
            && (window.contentView?.bounds.height ?? 0) >= 60
        let contentRendered = renderedContentIsVisible(in: window)
        let compositorOnScreen = isWindowOnScreen(window)
        let succeeded = window.isVisible
            && window.alphaValue > 0.99
            && intersectsDisplay
            && hasUsableSize
            && contentHasUsableSize
            && contentRendered
            && compositorOnScreen
        return "\(succeeded ? "PASS" : "FAIL") visible=\(window.isVisible) alpha=\(window.alphaValue) frame=\(NSStringFromRect(window.frame)) content=\(NSStringFromRect(window.contentView?.bounds ?? .zero)) rendered=\(contentRendered) onScreen=\(compositorOnScreen)"
    }

    var isHiddenForSmokeTest: Bool {
        guard let window else { return true }
        return !window.isVisible || window.alphaValue < 0.01
    }

    private func synchronizeVisibility(status: TranscriptionStatus, isEnabled: Bool) {
        if isEnabled, status != .idle {
            show(force: true)
        } else {
            hide()
        }
    }

    private func prepareForDisplay(_ window: NSWindow) {
        window.setContentSize(NSSize(width: Self.previewWidth, height: Self.previewHeight))
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.needsDisplay = true
    }

    private func renderedContentIsVisible(in window: NSWindow) -> Bool {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return false }

        view.cacheDisplay(in: view.bounds, to: bitmap)
        let xStep = max(1, bitmap.pixelsWide / 20)
        let yStep = max(1, bitmap.pixelsHigh / 8)

        for x in stride(from: 0, to: bitmap.pixelsWide, by: xStep) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStep) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    return true
                }
            }
        }
        return false
    }

    private func isWindowOnScreen(_ window: NSWindow) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionIncludingWindow,
            CGWindowID(window.windowNumber)
        ) as? [[String: Any]],
        let info = windowInfo.first
        else { return false }

        return info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private func recenter(on screen: NSScreen?) {
        guard let window, let screen else { return }
        let w = Self.previewWidth
        let h = Self.previewHeight
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
