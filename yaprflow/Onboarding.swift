import AppKit
import AVFoundation
import SwiftUI

private enum OnboardingStep {
    case welcome
    case modeSelection
    case grammarMode
    case permissions
}

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var streamingSelected: Bool = AppState.shared.streamingMode
    @State private var grammarSelected: Bool = false
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch step {
                case .welcome:        welcomeScreen
                case .modeSelection:  modeSelectionScreen
                case .grammarMode:    grammarModeScreen
                case .permissions:    permissionsScreen
                }
            }
            .transition(.opacity)
        }
        .frame(width: 520, height: 520)
    }

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
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
                withAnimation(.easeInOut(duration: 0.25)) { step = .modeSelection }
            } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 48)
        }
    }

    private var modeSelectionScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            Text("Pick a dictation mode")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
            Text("You can change this anytime from the menu bar.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 8)
            Spacer(minLength: 28)

            HStack(spacing: 12) {
                modeCard(
                    title: "Streaming",
                    tagline: "Text as you speak",
                    body: "Words appear in real time while you talk. Best for everyday dictation and longer recordings — no length limit.",
                    selected: streamingSelected,
                    onTap: { streamingSelected = true }
                )
                modeCard(
                    title: "Single-shot",
                    tagline: "Most accurate",
                    body: "Transcribes the whole clip when you stop. Slightly better accuracy on short dictations — best under 10 min.",
                    selected: !streamingSelected,
                    onTap: { streamingSelected = false }
                )
            }
            .padding(.horizontal, 28)

            Spacer()
            Button {
                AppState.shared.streamingMode = streamingSelected
                withAnimation(.easeInOut(duration: 0.25)) { step = .grammarMode }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 40)
        }
    }

    private var grammarModeScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            Text("Polish your dictation")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
            Text("Optional on-device AI features. Your text never leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 8)
            Spacer(minLength: 28)

            VStack(spacing: 12) {
                featureToggleCard(
                    title: "Auto-correct grammar",
                    body: "Fixes spelling, punctuation, and sentence structure after each dictation. The first use may take a moment to download the model.",
                    isOn: $grammarSelected
                )
                infoCard(
                    title: "Summarize on demand",
                    body: "Condense any transcript into a concise paragraph — available anytime from the menu bar after you dictate."
                )
            }
            .padding(.horizontal, 28)

            Spacer()
            Button {
                AppState.shared.grammarMode = grammarSelected
                withAnimation(.easeInOut(duration: 0.25)) { step = .permissions }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 40)
        }
    }

    private func featureToggleCard(
        title: String,
        body: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(isOn.wrappedValue ? 0.35 : 0.08), lineWidth: 1)
                        .frame(width: 20, height: 20)
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isOn.wrappedValue ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(isOn.wrappedValue ? 0.35 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func infoCard(title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "text.bullet.list")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.25))
                .frame(width: 20, height: 20)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func modeCard(
        title: String,
        tagline: String,
        body: String,
        selected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(tagline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected
                                     ? Color.white.opacity(0.80)
                                     : Color.white.opacity(0.45))
                Spacer(minLength: 10)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(selected ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(selected ? 0.35 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var permissionsScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white)
                .frame(width: 128, height: 128)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white.opacity(0.08))
                )
            Text("Enable microphone")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 24)
            Text("Yaprflow needs microphone access to transcribe\nyour voice. Audio never leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    handlePrimaryAction()
                } label: {
                    Text(primaryButtonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(OnboardingButtonStyle())
                .frame(width: 260)

                if micStatus != .authorized {
                    Button("Skip for now") { onComplete() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var primaryButtonTitle: String {
        switch micStatus {
        case .authorized:         return "You're all set"
        case .denied, .restricted: return "Open System Settings"
        case .notDetermined:       return "Grant microphone access"
        @unknown default:          return "Continue"
        }
    }

    private func handlePrimaryAction() {
        switch micStatus {
        case .authorized:
            onComplete()
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    if self.micStatus == .authorized {
                        self.onComplete()
                    }
                }
            }
        @unknown default:
            onComplete()
        }
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

    private static let defaultsKey = "yaprflow.didCompleteOnboarding"
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

        let rootView = OnboardingView { [weak self] in
            self?.complete()
        }

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
        window?.close() // windowWillClose will finish the cleanup.
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            self.window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
