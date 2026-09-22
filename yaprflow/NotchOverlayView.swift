import SwiftUI

enum NotchOverlayLayout {
    static func size(for status: TranscriptionStatus) -> CGSize {
        switch status {
        case .listening, .copied, .idle:
            return CGSize(width: 208, height: 36)
        case .preparing:
            return CGSize(width: 260, height: 38)
        case .error:
            return CGSize(width: 420, height: 60)
        }
    }
}

struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let statusFont = Font.system(size: 13, weight: .medium)

    var body: some View {
        let size = NotchOverlayLayout.size(for: state.status)

        HStack(alignment: .center, spacing: 8) {
            statusIndicator
                .frame(width: 12, height: 16)

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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(overlayShape.fill(Color.black.opacity(0.92)))
        .overlay(overlayShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var isError: Bool {
        if case .error = state.status { return true }
        return false
    }

    private var overlayShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                .frame(width: 8, height: 8)
                .modifier(RecordingPulse())
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14, weight: .bold))
                .accessibilityLabel("Copied")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14, weight: .semibold))
        case .preparing:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        case .idle:
            Color.clear
        }
    }
}

private struct LiveAudioLevelWaveform: View {
    private static let barCount = 28
    private static let minimumBarHeight: CGFloat = 3
    private static let maximumBarHeight: CGFloat = 18

    let level: Double
    @State private var history = [Double](repeating: 0, count: Self.barCount)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(history.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 2.5, height: barHeight(for: history[index]))
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
