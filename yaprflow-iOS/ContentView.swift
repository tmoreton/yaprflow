#if os(iOS)
import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = TranscriptionEngine.shared
    @StateObject private var history = HistoryStore.shared
    @State private var showHistory = false
    @State private var showAcknowledgements = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                    .padding(.horizontal, 20)

                Spacer(minLength: 0)

                Waveform(levels: engine.levels, isActive: engine.isRecording)
                    .frame(height: 96)
                    .padding(.horizontal, 24)

                statusText
                    .padding(.top, 16)
                    .frame(height: 22)

                Spacer(minLength: 0)

                if !engine.liveTranscript.isEmpty {
                    transcript
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                }

                micButton
                    .padding(.bottom, 56)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { engine.preload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                engine.applicationDidEnterBackground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            engine.applicationDidReceiveMemoryWarning()
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(history: history)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
        }
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showAcknowledgements = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About and acknowledgements")

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showHistory = true
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(history.items.isEmpty ? 0 : 0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(history.items.isEmpty)
            .opacity(history.items.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Recent transcripts")
        }
    }

    private var transcript: some View {
        Text(engine.liveTranscript)
            .font(.system(size: 17, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .animation(.easeInOut(duration: 0.15), value: engine.liveTranscript)
    }

    private var statusText: some View {
        Text(statusLabel)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.4))
            .animation(.easeInOut(duration: 0.2), value: statusLabel)
    }

    private var statusLabel: String {
        switch engine.status {
        case .idle: return engine.isRecording ? "" : "Tap to dictate"
        case .preparing(let msg): return msg
        case .listening: return "Listening"
        case .finishing: return "Finishing"
        case .copied: return "Copied"
        case .error(let msg): return msg
        }
    }

    private var micButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            engine.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(showsStopControl ? Color.red : Color.white)
                    .frame(width: 76, height: 76)
                    .shadow(color: showsStopControl ? Color.red.opacity(0.45) : .clear,
                            radius: showsStopControl ? 22 : 0)

                Image(systemName: showsStopControl ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(showsStopControl ? .white : .black)
            }
            .scaleEffect(showsStopControl ? 1.04 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: showsStopControl)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsStopControl ? "Stop recording" : "Start recording")
    }

    private var showsStopControl: Bool {
        engine.isRecording || engine.isRecordingPending
    }
}

// MARK: - Acknowledgements sheet

private struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let contents: String = {
        guard
            let url = Bundle.main.url(
                forResource: "Acknowledgements",
                withExtension: "txt"
            ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Acknowledgements are unavailable in this build."
        }
        return text
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Link(destination: URL(string: "https://yaprflow.com/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                            .font(.headline)
                    }

                    Divider()

                    Text(Self.contents)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - History sheet

private struct HistorySheet: View {
    @ObservedObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var copiedItem: String?
    @State private var showClearConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(0.6)
                        .textCase(.uppercase)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .disabled(history.items.isEmpty)
                    .accessibilityLabel("Clear transcript history")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

                VStack(spacing: 8) {
                    ForEach(history.items, id: \.self) { item in
                        HistoryRow(
                            text: item,
                            isCopied: copiedItem == item,
                            onCopy: { copy(item) }
                        )
                    }
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .confirmationDialog(
            "Clear recent transcripts?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved transcript text from this device.")
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedItem = text
        Task {
            try? await Task.sleep(for: .seconds(1.0))
            await MainActor.run {
                if copiedItem == text { copiedItem = nil }
            }
        }
    }
}

// MARK: - Waveform

private struct Waveform: View {
    let levels: [Float]
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let barSpacing: CGFloat = 2
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(count))
            let mid = geo.size.height / 2
            let maxHeight = geo.size.height * 0.95

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<count, id: \.self) { i in
                    let level = CGFloat(levels[i])
                    // Floor of ~1.5px so idle still shows a faint line.
                    let h = max(1.5, level * maxHeight)
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(barOpacity(level: level)))
                        .frame(width: barWidth, height: h)
                        .animation(.easeOut(duration: 0.08), value: levels[i])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .position(x: geo.size.width / 2, y: mid)
        }
    }

    private func barOpacity(level: CGFloat) -> Double {
        if isActive {
            return 0.35 + min(0.55, Double(level) * 0.8)
        } else {
            return 0.18 + min(0.4, Double(level) * 0.6)
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let text: String
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .top, spacing: 10) {
                Text(text)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCopied ? Color.green : .white.opacity(0.4))
                    .frame(width: 18)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}
#endif
