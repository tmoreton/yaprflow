import SwiftUI

struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let transcriptFont = Font.system(size: 15, weight: .medium)
    private static let twoLineHeight: CGFloat = 38

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator
                .frame(width: 14, height: 14)
                .padding(.top, 3)

            transcriptArea
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(2)
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if let live = liveTranscript {
            scrollingTranscript(live)
        } else {
            Text(displayText)
                .font(Self.transcriptFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var liveTranscript: String? {
        switch state.status {
        case .listening, .finishing:
            guard !state.liveTranscript.isEmpty else { return nil }
            let tailLimit = 400
            if state.liveTranscript.count <= tailLimit {
                return state.liveTranscript
            }
            return "…" + state.liveTranscript.suffix(tailLimit)
        default:
            return nil
        }
    }

    private func scrollingTranscript(_ text: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .id("live")
                    .font(Self.transcriptFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollDisabled(true)
            .onAppear { proxy.scrollTo("live", anchor: .bottom) }
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("live", anchor: .bottom)
                }
            }
        }
        .frame(height: Self.twoLineHeight)
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
