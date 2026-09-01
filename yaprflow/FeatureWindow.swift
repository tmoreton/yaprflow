import AppKit
import SwiftUI

struct FeatureWindowHeader: View {
    let symbolName: String
    let title: String
    let subtitle: String
    let accent: Color
    let badge: String
    let badgeSymbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Label(badge, systemImage: badgeSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct FeatureCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}

@MainActor
final class FeatureWindowController: NSObject, NSWindowDelegate {
    private let title: String
    private let contentSize: NSSize
    private let minimumSize: NSSize
    private let makeContent: () -> AnyView
    private var window: NSWindow?

    init<Content: View>(
        title: String,
        contentSize: NSSize,
        minimumSize: NSSize,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.contentSize = contentSize
        self.minimumSize = minimumSize
        self.makeContent = { AnyView(content()) }
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: makeContent())
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.setContentSize(contentSize)
        newWindow.minSize = minimumSize
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        newWindow.title = title
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()

        window = newWindow
        NSApp.setActivationPolicy(.regular)
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            await Task.yield()

            let hasAnotherVisibleWindow = NSApp.windows.contains { candidate in
                candidate.isVisible && candidate.canBecomeKey
            }
            if !hasAnotherVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
