import AppKit
import Combine
import FoundationModels
import SwiftUI

@MainActor
final class TranscriptAIModel: ObservableObject {
    static let defaultPrompt = """
    Summarize this transcript into concise bullet points. Preserve important details, decisions, names, and follow-up actions.
    """

    private static let promptKey = "yaprflow.ai.prompt"

    @Published var prompt: String {
        didSet {
            UserDefaults.standard.set(prompt, forKey: Self.promptKey)
        }
    }
    @Published var result = ""
    @Published private(set) var isRunning = false
    @Published private(set) var processingMessage: String?
    @Published private(set) var isModelAvailable = false
    @Published private(set) var availabilityMessage = "Checking Apple Intelligence…"
    @Published var errorMessage: String?

    init() {
        prompt = UserDefaults.standard.string(forKey: Self.promptKey) ?? Self.defaultPrompt
        refreshAvailability()
    }

    func refreshAvailability() {
        guard #available(macOS 26.0, *) else {
            isModelAvailable = false
            availabilityMessage = "AI Summary requires macOS 26 or later."
            return
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            isModelAvailable = true
            availabilityMessage = "Apple Intelligence is ready and runs on this Mac."
        case .unavailable(.deviceNotEligible):
            isModelAvailable = false
            availabilityMessage = "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            isModelAvailable = false
            availabilityMessage = "Turn on Apple Intelligence in System Settings to use AI Summary."
        case .unavailable(.modelNotReady):
            isModelAvailable = false
            availabilityMessage = "The on-device model is still downloading or not ready."
        case .unavailable:
            isModelAvailable = false
            availabilityMessage = "Apple Intelligence is not currently available."
        }
    }

    func resetPrompt() {
        prompt = Self.defaultPrompt
    }

    func clearOutput() {
        result = ""
        errorMessage = nil
    }

    func run(transcript: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        refreshAvailability()
        guard isModelAvailable else { return }
        guard !trimmedPrompt.isEmpty else {
            errorMessage = "Enter a prompt describing what you want the model to do."
            return
        }
        guard !trimmedTranscript.isEmpty else {
            errorMessage = "Create a transcript before generating an AI summary."
            return
        }

        isRunning = true
        processingMessage = "Preparing transcript…"
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.processingMessage = nil
            }

            do {
                if #available(macOS 26.0, *) {
                    self.result = try await TranscriptAIProcessor.generate(
                        prompt: trimmedPrompt,
                        transcript: trimmedTranscript,
                        progress: { progress in
                            self.processingMessage = progress.message
                        }
                    )
                }
            } catch {
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return "Apple Intelligence could not process this transcript. Try a shorter transcript or prompt."
        }
        return description
    }
}

struct TranscriptAIView: View {
    @ObservedObject private var appState = AppState.shared
    @StateObject private var ai = TranscriptAIModel()
    @StateObject private var history = TranscriptHistoryModel()

    private let presets: [(title: String, prompt: String)] = [
        (
            "Summarize",
            "Summarize this transcript into concise bullet points. Preserve important details, decisions, names, and follow-up actions."
        ),
        (
            "Action Items",
            "Extract the action items from this transcript. For each one, include the owner and deadline when stated. Do not invent missing details."
        ),
        (
            "Rewrite",
            "Rewrite this transcript as clear, polished prose. Preserve its meaning and factual details while removing repetition and filler."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Summary")
                    .font(.title3.weight(.semibold))

                Spacer()

                Label("On-device", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sourceRow

            Divider()

            promptSection

            if let errorMessage = ai.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            resultSection
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            ai.refreshAvailability()
            history.refresh(selectLatest: true)
        }
        .onChange(of: appState.lastTranscript) { _, _ in
            history.refresh(selectLatest: true)
        }
        .onChange(of: history.selection) { oldSelection, newSelection in
            if oldSelection != newSelection {
                ai.clearOutput()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowTranscriptArchiveChanged)) {
            history.handleArchiveChange($0)
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: selectedTranscript.isEmpty ? "waveform.slash" : "waveform")
                .foregroundStyle(.secondary)

            if history.items.isEmpty {
                Text(selectedTranscript.isEmpty ? "No transcripts yet" : "Latest transcript")
                    .font(.callout)
                    .foregroundStyle(selectedTranscript.isEmpty ? .secondary : .primary)
            } else {
                Menu {
                    ForEach(history.items) { item in
                        Button {
                            history.selection = item.id
                        } label: {
                            if history.selection == item.id {
                                Label(sourceTitle(for: item), systemImage: "checkmark")
                            } else {
                                Text(sourceTitle(for: item))
                            }
                        }
                    }
                } label: {
                    Text(selectedSourceTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Transcript")
                .accessibilityValue(selectedSourceTitle)
            }

            Text(sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                history.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh transcript history")
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt")
                    .font(.callout.weight(.medium))

                Spacer()

                Menu("Presets") {
                    ForEach(presets, id: \.title) { preset in
                        Button(preset.title) {
                            ai.prompt = preset.prompt
                        }
                    }

                    Divider()

                    Button("Reset to Default") {
                        ai.resetPrompt()
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            TextEditor(text: $ai.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 72, maxHeight: 92)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator, lineWidth: 1)
                }

            HStack(spacing: 7) {
                Image(systemName: ai.isModelAvailable ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(ai.isModelAvailable ? .green : .secondary)
                Text(ai.processingMessage ?? ai.availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if ai.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(ai.isRunning ? "Working…" : "Run") {
                    ai.run(transcript: selectedTranscript)
                }
                .buttonStyle(.borderedProminent)
                .disabled(runIsDisabled)
            }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Result")
                    .font(.callout.weight(.medium))

                Spacer()

                Button("Copy", systemImage: "doc.on.clipboard") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ai.result, forType: .string)
                }
                .buttonStyle(.plain)
                .disabled(ai.result.isEmpty)
            }

            TextEditor(text: $ai.result)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 120)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator, lineWidth: 1)
                }
        }
    }

    private var sourceDescription: String {
        let transcript = selectedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return "Record something first"
        }
        let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
        return "\(wordCount) \(wordCount == 1 ? "word" : "words")"
    }

    private var selectedTranscript: String {
        history.selectedItem?.transcript ?? appState.lastTranscript
    }

    private var selectedSourceTitle: String {
        guard let selectedItem = history.selectedItem else { return "Choose a transcript" }
        return sourceTitle(for: selectedItem)
    }

    private func sourceTitle(for item: TranscriptHistoryItem) -> String {
        if item.id == history.items.first?.id {
            return "Latest · \(item.title) · \(item.dateDescription)"
        }
        return "\(item.title) · \(item.dateDescription)"
    }

    private var runIsDisabled: Bool {
        ai.isRunning
            || !ai.isModelAvailable
            || selectedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ai.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
enum TranscriptAIWindowController {
    static let shared = FeatureWindowController(
        title: "AI Summary",
        contentSize: NSSize(width: 520, height: 500),
        minimumSize: NSSize(width: 480, height: 440)
    ) {
        TranscriptAIView()
    }
}
