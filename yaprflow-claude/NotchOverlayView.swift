import SwiftUI

struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator
                .frame(width: 14, height: 14)
                .padding(.top, 4)

            ScrollView(.vertical, showsIndicators: false) {
                Text(displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .animation(.easeOut(duration: 0.12), value: displayText)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDisabled(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(2)
    }

    private var displayText: String {
        switch state.status {
        case .idle:
            return ""
        case .preparing(let message):
            return message
        case .listening:
            return state.liveTranscript.isEmpty ? "Listening…" : state.liveTranscript
        case .finishing:
            return state.liveTranscript.isEmpty ? "Processing…" : state.liveTranscript
        case .copied:
            return "Copied to clipboard"
        case .error(let message):
            return message
        }
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
                .font(.system(size: 14, weight: .semibold))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14, weight: .semibold))
        case .preparing, .finishing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .idle:
            Color.clear
        }
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
