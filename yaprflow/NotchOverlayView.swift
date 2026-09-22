import SwiftUI

struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let transcriptFont = Font.system(size: 15, weight: .medium)
    private static let cornerRadius: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator
                .frame(width: 18, height: 18)
                .padding(.top, 3)

            if state.status == .listening {
                LiveAudioLevelWaveform(level: state.audioLevel)
                    .frame(maxWidth: .infinity)
            } else {
                Text(displayText)
                    .font(Self.transcriptFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(width: 520, height: 68, alignment: .leading)
        .background(overlayShape.fill(Color.black.opacity(0.92)))
        .overlay(overlayShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var overlayShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
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
    private static let barCount = 48
    private static let minimumBarHeight: CGFloat = 5
    private static let maximumBarHeight: CGFloat = 30

    let level: Double
    @State private var history = [Double](repeating: 0, count: Self.barCount)

    var body: some View {
        HStack(spacing: 5) {
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
