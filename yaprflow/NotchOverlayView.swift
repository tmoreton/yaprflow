import AppKit
import SwiftUI

/// The floating pill that appears while yaprflow is recording / processing.
///
/// Lives at the **bottom-center** of the screen (previously top-attached to
/// the display notch — hence the filename). The pill shows three animated
/// audio-level bars on the left and the live transcript / status text on the
/// right, on a dark `hudWindow` blur. Bouncing-bar visualization matches the
/// Wispr Flow shape: a clear visual signal that the mic is actually live and
/// the user is being heard.
struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let transcriptFont = Font.system(size: 14, weight: .medium)
    private static let cornerRadius: CGFloat = 18
    private static let maxCharsPerLine = 56

    var body: some View {
        pill
            // Window is a fixed-size transparent canvas (we deliberately don't
            // let NSHostingController auto-shrink to the SwiftUI intrinsic, or
            // an idle/empty body would collapse the window to 0×0). Filling
            // the container and centering the pill puts it in the middle of
            // the canvas regardless of how big the inner content is.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pill: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingIndicator

            if !displayText.isEmpty {
                Text(displayText)
                    .font(Self.transcriptFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch state.status {
        case .listening:
            LevelBarsView(level: state.inputLevel, active: true)
        case .preparing, .finishing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .correcting, .summarizing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .semibold))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 16, weight: .semibold))
        case .idle:
            // Idle state shouldn't normally render — the window is hidden
            // outside of an active session — but show static bars as a
            // fallback rather than collapsing the layout to zero width.
            LevelBarsView(level: 0, active: false)
        }
    }

    private var displayText: String {
        switch state.status {
        case .idle:                       return ""
        case .preparing(let message):     return message
        case .listening:
            return state.liveTranscript.isEmpty ? "Listening…" : Self.wrappedTail(of: state.liveTranscript)
        case .finishing:
            return state.liveTranscript.isEmpty ? "Processing…" : Self.wrappedTail(of: state.liveTranscript)
        case .correcting(let message):    return message
        case .summarizing:                return "Summarizing…"
        case .copied:                     return "Copied"
        case .error(let message):         return message
        }
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
}

/// Three vertical bars whose heights track the live input level, with a tiny
/// per-bar scale offset so the cluster feels alive rather than three identical
/// pumps. Easing on the height keeps it from looking jittery on bursty buffers.
private struct LevelBarsView: View {
    let level: Float
    let active: Bool

    private static let baseHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 18
    private static let barWidth: CGFloat = 3

    // Per-bar gain — middle bar reads slightly higher so the silhouette
    // feels like a sound wave rather than a fence.
    private static let barScales: [Float] = [0.85, 1.15, 0.95]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.barScales.indices, id: \.self) { idx in
                bar(scale: Self.barScales[idx])
            }
        }
    }

    private func bar(scale: Float) -> some View {
        // Apply a soft gain on top of the raw RMS — speech sits around
        // 0.05–0.25 on a typical mic and we want the bars to reach the
        // top of their range on confident speech, not require shouting.
        let amplified = min(1.0, level * scale * 3.5)
        let height: CGFloat = active
            ? max(Self.baseHeight, CGFloat(amplified) * Self.maxHeight)
            : Self.baseHeight
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white.opacity(0.92))
            .frame(width: Self.barWidth, height: height)
            .animation(.easeOut(duration: 0.08), value: height)
    }
}

/// Wraps `NSVisualEffectView` so SwiftUI can use a real AppKit blur (the
/// `.regularMaterial` / `.ultraThinMaterial` SwiftUI materials don't include
/// the darker `hudWindow` look that fits a floating overlay against arbitrary
/// app backgrounds).
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
