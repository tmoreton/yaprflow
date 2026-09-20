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
            availabilityMessage = "Transcript tools require macOS 26 or later."
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
            availabilityMessage = "Turn on Apple Intelligence in System Settings to use transcript tools."
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
            errorMessage = "Select or create a transcript before running this prompt."
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
    @State private var search = ""

    let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

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
        VStack(spacing: 0) {
            transcriptHeader
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider()

            HSplitView {
                historySidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)

                workspace
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            ai.refreshAvailability()
            history.refresh(selectLatest: true)
            TranscriptMetadataEnricher.shared.enqueueMissingTranscripts()
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

    private var transcriptHeader: some View {
        HStack(spacing: 14) {
            FeatureWindowHeader(
                symbolName: "sparkles",
                title: "Transcript tools",
                subtitle: "Browse saved dictations and run reusable AI prompts.",
                accent: .purple,
                badge: providerBadge,
                badgeSymbol: providerBadgeSymbol
            )

            Spacer(minLength: 12)

            Button("AI Settings", systemImage: "slider.horizontal.3") {
                onOpenSettings()
            }
            .help("Choose an AI provider and model")
        }
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            }

            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Text(search.isEmpty ? "\(history.items.count)" : "\(filteredItems.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = history.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if filteredItems.isEmpty {
                historyEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredItems) { item in
                            Button {
                                history.selection = item.id
                            } label: {
                                transcriptRow(item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select \(item.title)")
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    history.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh history")

                Button {
                    history.revealSelection()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")

                Spacer()

                Button("Open") {
                    history.openSelected()
                }
                .disabled(history.selectedItem == nil)

                Button("Copy", systemImage: "doc.on.clipboard") {
                    history.copySelected()
                }
                .disabled(history.selectedItem?.transcript.isEmpty != false)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func transcriptRow(_ item: TranscriptHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(item.dateDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let topic = item.topic {
                Text(topic)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(item.preview)
                .font(.caption)
                .foregroundStyle(item.topic == nil ? .secondary : .tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            history.selection == item.id ? Color.accentColor.opacity(0.13) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }

    private var historyEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: search.isEmpty ? "waveform" : "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No transcripts yet" : "No matching transcripts")
                .font(.callout.weight(.medium))
            Text(search.isEmpty ? "Quick dictations will appear here." : "Try a different search.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var workspace: some View {
        if selectedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Choose a transcript",
                systemImage: "text.document",
                description: Text("Record a quick dictation or select one from history to use transcript tools.")
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(history.selectedItem?.title ?? "Latest transcript")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(sourceDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let selectedItem = history.selectedItem {
                        Text(selectedItem.dateDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            .padding(18)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt")
                    .font(.callout.weight(.medium))

                Spacer()

                Menu("Use preset") {
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

                Button(ai.isRunning ? "Working…" : "Run prompt") {
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

    private var filteredItems: [TranscriptHistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.items }
        return history.items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.topic?.localizedCaseInsensitiveContains(query) == true
                || item.generatedDescription?.localizedCaseInsensitiveContains(query) == true
                || item.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    private var runIsDisabled: Bool {
        ai.isRunning
            || !ai.isModelAvailable
            || selectedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ai.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
