#if os(iOS)
import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var session: KeyboardSession

    var body: some View {
        VStack(spacing: 6) {
            topBar
                .padding(.horizontal, 8)
                .padding(.top, 4)

            keyboardBody
        }
    }

    // MARK: - Top bar — centered status, mic anchored on the right

    private var topBar: some View {
        ZStack {
            statusContent

            HStack(spacing: 8) {
                Spacer()
                micButton
            }
        }
        .frame(height: 38)
    }

    private var micButton: some View {
        Button {
            session.tapMic()
        } label: {
            ZStack {
                Circle()
                    .fill(micFill)
                    .frame(width: 32, height: 32)
                    .shadow(color: micShadow, radius: 8)

                Image(systemName: micIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(micIconColor)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: session.status)
        }
        .buttonStyle(.plain)
    }

    private var micIcon: String {
        switch session.status {
        case .awaitingApp, .awaitingReturn: return "arrow.up.forward.app.fill"
        case .inserted: return "checkmark"
        case .error: return "exclamationmark"
        default: return "mic.fill"
        }
    }

    private var micFill: Color {
        switch session.status {
        case .awaitingApp, .awaitingReturn: return .blue
        case .inserted: return .green
        case .error: return .orange
        default: return Color(uiColor: .label)
        }
    }

    private var micShadow: Color {
        switch session.status {
        case .awaitingApp, .awaitingReturn: return Color.blue.opacity(0.45)
        default: return .clear
        }
    }

    private var micIconColor: Color {
        switch session.status {
        case .awaitingApp, .awaitingReturn, .inserted, .error: return .white
        default: return Color(uiColor: .systemBackground)
        }
    }

    /// What sits centered in the top bar (history pill or status text).
    @ViewBuilder
    private var statusContent: some View {
        switch session.status {
        case .idle:
            if !session.history.isEmpty {
                historyPill
            } else {
                Text("Tap mic to dictate in Yaprflow")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        case .awaitingApp:
            Text("Opening Yaprflow…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.blue)
        case .awaitingReturn:
            Text("Swipe back when finished")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.blue)
        case .inserted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Inserted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            }
        case .error(let m):
            Text(m)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var historyPill: some View {
        if let latest = session.history.first {
            Button {
                session.insertHistoryItem(latest)
            } label: {
                Text(Self.truncate(latest, max: 32))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(uiColor: .systemGray4)))
            }
            .buttonStyle(.plain)
        }
    }

    private static func truncate(_ s: String, max: Int) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Keyboard rows

    private var keyboardBody: some View {
        VStack(spacing: 7) {
            ForEach(Array(KeyboardLayout.rows(for: session.page).enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func rowView(_ row: KeyRowSpec) -> some View {
        let totalWeight: CGFloat = row.keys.reduce(0) { $0 + $1.1 }
        let inset: CGFloat = totalWeight == 9 ? 18 : 0

        return GeometryReader { geo in
            RowKeys(
                row: row,
                width: geo.size.width - inset * 2,
                totalWeight: totalWeight,
                session: session
            )
            .padding(.horizontal, inset)
        }
        .frame(height: 42)
    }
}

// MARK: - One row's worth of keys

private struct RowKeys: View {
    let row: KeyRowSpec
    let width: CGFloat
    let totalWeight: CGFloat
    @ObservedObject var session: KeyboardSession

    var body: some View {
        let spacing: CGFloat = 6
        let keyCount = CGFloat(row.keys.count)
        let totalSpacing = spacing * max(0, keyCount - 1)
        let availableForKeys = max(0, width - totalSpacing)
        let unit = totalWeight > 0 ? availableForKeys / totalWeight : 0

        return HStack(spacing: spacing) {
            ForEach(Array(row.keys.enumerated()), id: \.offset) { _, pair in
                KeyView(key: pair.0, session: session)
                    .frame(width: unit * pair.1)
            }
        }
    }
}

// MARK: - Individual key

private struct KeyView: View {
    let key: Key
    @ObservedObject var session: KeyboardSession
    @Environment(\.colorScheme) private var scheme

    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(pressed ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.05), value: pressed)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { _, state, _ in state = true }
                .onEnded { _ in handlePressUp() }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch key {
        case .letter(let ch):
            Text(session.shift == .lowercase ? ch.lowercased() : ch.uppercased())
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
        case .digit(let s):
            Text(s)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
        case .symbol(let s):
            Text(s)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
        case .shift:
            Image(systemName: shiftSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
        case .backspace:
            Image(systemName: "delete.left")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
        case .page(let target):
            Text(pageLabel(target))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        case .globe:
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
        case .space:
            Text("space")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
        case .return:
            Text("return")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
        case .mic:
            EmptyView()
        }
    }

    private var fill: Color {
        let dark = scheme == .dark
        switch key {
        case .shift:
            if session.shift == .capsLock || session.shift == .uppercaseOnce {
                return Color(uiColor: dark ? .systemGray3 : .white)
            }
            return controlKeyFill(dark: dark)
        case .backspace, .page, .globe, .return:
            return controlKeyFill(dark: dark)
        case .space:
            return primaryKeyFill(dark: dark)
        default:
            return primaryKeyFill(dark: dark)
        }
    }

    private func primaryKeyFill(dark: Bool) -> Color {
        Color(uiColor: dark ? UIColor.systemGray2 : UIColor.white)
    }

    private func controlKeyFill(dark: Bool) -> Color {
        Color(uiColor: dark ? UIColor.systemGray3 : UIColor.systemGray4)
    }

    private var shiftSymbol: String {
        switch session.shift {
        case .lowercase: return "shift"
        case .uppercaseOnce: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }

    private func pageLabel(_ p: KeyboardPage) -> String {
        switch p {
        case .letters: return "ABC"
        case .numbers: return "123"
        case .symbols: return "#+="
        }
    }

    private func handlePressUp() {
        switch key {
        case .letter(let ch): session.tapLetter(ch)
        case .digit(let s): session.tapRawText(s)
        case .symbol(let s): session.tapRawText(s)
        case .shift: session.tapShift()
        case .backspace: session.tapBackspace()
        case .page(let p): session.switchPage(p)
        case .globe: session.handleGlobe()
        case .space: session.tapSpace()
        case .return: session.tapReturn()
        case .mic: break
        }
    }
}
#endif
