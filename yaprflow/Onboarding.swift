import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

private enum OnboardingStep {
    case welcome
    case permissions
}

struct OnboardingView: View {
    let onComplete: () -> Void
    let onRestart: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @State private var hasRequestedScreenCapture = false
    @State private var screenCaptureRequiresRestart = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch step {
                case .welcome:     welcomeScreen
                case .permissions: permissionsScreen
                }
            }
            .transition(.opacity)
        }
        .frame(width: 520, height: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatuses()
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: onboardingIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text("Yaprflow")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 24)
            Text("Private, offline dictation for macOS")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 8)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { step = .permissions }
            } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 48)
        }
    }

    private var permissionsScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white)
                .frame(width: 128, height: 128)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white.opacity(0.08))
                )
            Text("Enable permissions")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 24)
            Text("Dictation needs your microphone. Meeting Notes also needs\nScreen & System Audio access. Audio never leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 8)

            VStack(spacing: 10) {
                permissionRow(
                    title: "Microphone",
                    detail: "Dictation and your side of meetings",
                    isGranted: micStatus == .authorized
                )
                permissionRow(
                    title: "Screen & System Audio",
                    detail: "Mac audio in Meeting Notes — your screen is never saved",
                    isGranted: screenCaptureGranted
                )
            }
            .frame(width: 360)
            .padding(.top, 22)

            Spacer()
            VStack(spacing: 12) {
                Button {
                    handlePrimaryAction()
                } label: {
                    Text(primaryButtonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(OnboardingButtonStyle())
                .frame(width: 260)

                if micStatus != .authorized || !screenCaptureGranted {
                    Button(skipButtonTitle) { onComplete() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var primaryButtonTitle: String {
        if screenCaptureRequiresRestart {
            return "Restart Yaprflow"
        }
        if micStatus != .authorized {
            switch micStatus {
            case .denied, .restricted: return "Open Microphone Settings"
            case .notDetermined: return "Allow microphone"
            case .authorized: break
            @unknown default: return "Open Microphone Settings"
            }
        }
        if !screenCaptureGranted {
            return hasRequestedScreenCapture
                ? "Open Screen & Audio Settings"
                : "Allow Screen & System Audio"
        }
        return "Continue"
    }

    private var skipButtonTitle: String {
        micStatus == .authorized
            ? "Continue with Dictation only"
            : "Set up later"
    }

    private func handlePrimaryAction() {
        if screenCaptureRequiresRestart {
            onRestart()
            return
        }
        if micStatus != .authorized {
            switch micStatus {
            case .authorized:
                break
            case .denied, .restricted:
                openPrivacySettings(pane: "Privacy_Microphone")
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { refreshPermissionStatuses() }
                }
            @unknown default:
                openPrivacySettings(pane: "Privacy_Microphone")
            }
            return
        }

        guard !screenCaptureGranted else {
            onComplete()
            return
        }

        if hasRequestedScreenCapture {
            openPrivacySettings(pane: "Privacy_ScreenCapture")
        } else {
            hasRequestedScreenCapture = true
            screenCaptureGranted = CGRequestScreenCaptureAccess()
            screenCaptureRequiresRestart = screenCaptureGranted
        }
    }

    private func permissionRow(title: String, detail: String, isGranted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isGranted ? .green : Color.white.opacity(0.45))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var onboardingIcon: NSImage {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        return image
    }

    private func refreshPermissionStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let wasGranted = screenCaptureGranted
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if hasRequestedScreenCapture, !wasGranted, screenCaptureGranted {
            screenCaptureRequiresRestart = true
        }
    }

    private func openPrivacySettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private static let defaultsKey = "yaprflow.didCompleteOnboarding.v2"
    private var window: NSWindow?

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = OnboardingView(
            onComplete: { [weak self] in self?.complete() },
            onRestart: { [weak self] in self?.restart() }
        )

        let hosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.setContentSize(NSSize(width: 480, height: 520))
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.title = ""
        newWindow.isMovableByWindowBackground = true
        newWindow.backgroundColor = .black
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()

        window = newWindow

        // Temporarily show the app in the Dock so the onboarding window is
        // focusable; we flip back to .accessory on completion.
        NSApp.setActivationPolicy(.regular)
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
        window?.close() // windowWillClose will finish the cleanup.
    }

    private func restart() {
        complete()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
