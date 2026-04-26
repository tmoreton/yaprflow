import SwiftUI

struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let transcriptFont = Font.system(size: 15, weight: .medium)
    private static let subtitleFont = Font.system(size: 12, weight: .regular)
    private static let maxCharsPerLine = 56
    private static let cornerRadius: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator
                .frame(width: 14, height: 14)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(Self.transcriptFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: true, vertical: true)

                if showSubtitle {
                    Text(subtitleText)
                        .font(Self.subtitleFont)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(pillShape.fill(Color.black.opacity(0.92)))
        .overlay(pillShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: true)
    }

    private var pillShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: Self.cornerRadius,
            bottomTrailingRadius: Self.cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var displayText: String {
        switch state.status {
        case .idle:
            return ""
        case .preparing(let message):
            return message
        case .listening:
            return state.liveTranscript.isEmpty ? "Listening…" : Self.wrappedTail(of: state.liveTranscript)
        case .finishing:
            return state.liveTranscript.isEmpty ? "Processing…" : Self.wrappedTail(of: state.liveTranscript)
        case .correcting(let message):
            return message
        case .copied:
            return copiedDisplayText
        case .error(let message):
            return message
        }
    }

    /// Shows appropriate text for the copied state.
    /// For long transcripts, shows a simple confirmation instead of truncated text.
    private var copiedDisplayText: String {
        // If we have a grammar-corrected version different from original, show that
        if !state.lastTranscript.isEmpty &&
           !state.lastOriginalTranscript.isEmpty &&
           state.lastTranscript != state.lastOriginalTranscript {
            return "Grammar corrected"
        }

        // For regular transcription, show tail or confirmation
        if state.liveTranscript.isEmpty {
            return "Copied to clipboard"
        }

        // For short text, show the actual content
        if state.liveTranscript.count <= Self.maxCharsPerLine * 2 {
            return state.liveTranscript
        }

        // For long text, just show confirmation
        return "Copied to clipboard"
    }

    private var showSubtitle: Bool {
        guard case .copied = state.status else { return false }
        // Show subtitle when we have grammar correction results
        return !state.lastTranscript.isEmpty &&
               !state.lastOriginalTranscript.isEmpty &&
               state.lastTranscript != state.lastOriginalTranscript
    }

    private var subtitleText: String {
        guard showSubtitle else { return "" }
        // Show a hint that original is available in menu
        return "View original in menu ⌄"
    }

    private static func wrappedTail(of text: String) -> String {
        wrapLines(text, maxCharsPerLine: maxCharsPerLine)
            .suffix(2)
            .joined(separator: "\n")
    }

    private static func wrapLines(_ text: String, maxCharsPerLine: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate: String = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= maxCharsPerLine {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = word.count > maxCharsPerLine ? String(word.prefix(maxCharsPerLine)) : String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state.status {
        case .listening:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .modifier(RecordingPulse())
        case .correcting:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
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
