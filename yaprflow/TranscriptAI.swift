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
    @Published private(set) var availabilityMessage = "Checking AI provider…"
    @Published var errorMessage: String?

    init() {
        prompt = UserDefaults.standard.string(forKey: Self.promptKey) ?? Self.defaultPrompt
        refreshAvailability()
    }

    func refreshAvailability() {
        let settings = AIProviderSettings.shared
        if settings.provider != .appleIntelligence {
            isModelAvailable = settings.isConfigured
            if settings.isConfigured {
                availabilityMessage = "Configured for \(settings.provider.displayName) · \(settings.selectedModel)"
            } else if settings.selectedModel.isEmpty {
                availabilityMessage = "Choose a \(settings.provider.displayName) model in Settings."
            } else {
                availabilityMessage = "Add your \(settings.provider.displayName) API key in Settings."
            }
            return
        }

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

        let provider = AIProviderSettings.shared.provider
        let remoteConfiguration: AIChatConfiguration?
        do {
            remoteConfiguration = provider == .appleIntelligence
                ? nil
                : try AIProviderSettings.shared.configuration()
        } catch {
            errorMessage = Self.message(for: error)
            Telemetry.shared.track(.aiSummaryFailed(provider, Self.telemetryFailure(for: error)))
            return
        }

        isRunning = true
        processingMessage = "Preparing transcript…"
        errorMessage = nil
        Telemetry.shared.track(.aiSummaryStarted(provider))
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.processingMessage = nil
            }

            do {
                if provider == .appleIntelligence {
                    if #available(macOS 26.0, *) {
                        self.result = try await TranscriptAIProcessor.generate(
                            prompt: trimmedPrompt,
                            transcript: trimmedTranscript,
                            progress: { progress in
                                self.processingMessage = progress.message
                            }
                        )
                    }
                } else {
                    guard let configuration = remoteConfiguration else {
                        throw AIProviderError.unsupportedProvider
                    }
                    self.result = try await RemoteTranscriptAIProcessor.generate(
                        prompt: trimmedPrompt,
                        transcript: trimmedTranscript,
                        configuration: configuration,
                        progress: { self.processingMessage = $0 }
                    )
                }
                Telemetry.shared.track(.aiSummaryCompleted(provider))
            } catch {
                self.errorMessage = Self.message(for: error)
                Telemetry.shared.track(.aiSummaryFailed(provider, Self.telemetryFailure(for: error)))
            }
        }
    }

    private static func message(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return "The selected model could not process this transcript. Try again or choose another model."
        }
        return description
    }

    private static func telemetryFailure(for error: Error) -> TelemetryFailure {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case let .httpStatus(status, _):
                if status == 401 || status == 403 { return .authentication }
                if status == 429 { return .rateLimit }
                return .provider
            case .invalidResponse, .emptyResponse, .truncatedResponse:
                return .invalidResponse
            case .ollamaUnavailable:
                return .network
            case .missingModel, .missingAPIKey, .unsupportedProvider:
                return .provider
            }
        }
        if error is URLError { return .network }
        return .other
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
        VStack(alignment: .leading, spacing: 14) {
            FeatureWindowHeader(
                symbolName: "sparkles",
                title: "AI Summary",
                subtitle: "Summarize or transform any saved transcript.",
                accent: .purple,
                badge: providerBadge,
                badgeSymbol: providerBadgeSymbol
            )

            FeatureCard {
                sourceRow
            }

            FeatureCard {
                promptSection
            }

            if let errorMessage = ai.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            FeatureCard {
                resultSection
            }
            .frame(maxHeight: .infinity)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowAIProviderSettingsChanged)) { _ in
            ai.refreshAvailability()
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

            if selectedProvider.sendsTranscriptOffDevice {
                Text("Run sends this transcript and prompt to \(selectedProvider.displayName). Your provider may charge for the request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedProvider: AIProviderKind {
        AIProviderSettings.shared.provider
    }

    private var providerBadge: String {
        switch selectedProvider {
        case .appleIntelligence: "On-device"
        case .openAI, .openRouter: "Cloud"
        case .ollama: "Ollama"
        }
    }

    private var providerBadgeSymbol: String {
        switch selectedProvider {
        case .appleIntelligence: "lock.fill"
        case .openAI, .openRouter: "cloud"
        case .ollama: "desktopcomputer"
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
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator, lineWidth: 1)
                }
        }
        .frame(maxHeight: .infinity)
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
