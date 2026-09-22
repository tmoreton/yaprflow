import SwiftUI

enum NotchOverlayLayout {
    static func size(for status: TranscriptionStatus) -> CGSize {
        if case .error = status {
            return CGSize(width: 480, height: 64)
        }
        return CGSize(width: 320, height: 44)
    }
}

struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let statusFont = Font.system(size: 14, weight: .medium)

    var body: some View {
        let size = NotchOverlayLayout.size(for: state.status)

        HStack(alignment: .center, spacing: 10) {
            statusIndicator
                .frame(width: 16, height: 16)

            if state.status == .listening {
                LiveAudioLevelWaveform(level: state.audioLevel)
                    .frame(maxWidth: .infinity)
            } else {
                Text(displayText)
                    .font(Self.statusFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(isError ? 2 : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(overlayShape.fill(Color.black.opacity(0.92)))
        .overlay(overlayShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var isError: Bool {
        if case .error = state.status { return true }
        return false
    }

    private var overlayShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var displayText: String {
        switch state.status {
        case .idle:
            return ""
        case .preparing(let message):
            return message
        case .listening:
            return "Listening…"
        case .copied:
            return copiedDisplayText
        case .error(let message):
            return message
        }
    }

    /// Shows appropriate text for the copied state.
    private var copiedDisplayText: String {
        return "Copied to clipboard"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state.status {
        case .listening:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .modifier(RecordingPulse())
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .bold))
                .accessibilityLabel("Copied")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14, weight: .semibold))
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .idle:
            Color.clear
        }
    }
}

private struct LiveAudioLevelWaveform: View {
    private static let barCount = 36
    private static let minimumBarHeight: CGFloat = 4
    private static let maximumBarHeight: CGFloat = 24

    let level: Double
    @State private var history = [Double](repeating: 0, count: Self.barCount)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(history.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 3, height: barHeight(for: history[index]))
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.maximumBarHeight)
        .animation(.easeOut(duration: 0.12), value: history)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(min(1, max(0, newLevel)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone audio level")
        .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) percent")
    }

    private func barHeight(for sample: Double) -> CGFloat {
        Self.minimumBarHeight
            + CGFloat(sample) * (Self.maximumBarHeight - Self.minimumBarHeight)
    }
}

private struct RecordingPulse: ViewModifier {
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
