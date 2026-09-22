import AppKit
import Combine
import SwiftUI

@MainActor
private final class MeetingMemoryModel: ObservableObject {
    @Published var answer = ""
    @Published private(set) var isRunning = false
    @Published private(set) var progressMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var evidenceHits: [MeetingSearchHit] = []
    private var generationID = UUID()

    func generateSummary(
        for meeting: MeetingRecord,
        completion: @escaping (MeetingGeneratedNotes) -> Void
    ) {
        guard !meeting.transcript.isEmpty, !isRunning else { return }
        let requestID = UUID()
        generationID = requestID
        isRunning = true
        answer = ""
        errorMessage = nil
        evidenceHits = []
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generationID == requestID {
                    self.isRunning = false
                    self.progressMessage = nil
                }
            }
            do {
                let notes = try await MeetingAIService.generateNotes(
                    for: meeting,
                    progress: { message in
                        guard self.generationID == requestID else { return }
                        self.progressMessage = message
                    }
                )
                guard self.generationID == requestID else { return }
                completion(notes)
            } catch {
                guard self.generationID == requestID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func ask(question: String, meetings: [MeetingRecord], includeAllSegments: Bool = false) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let requestID = UUID()
        generationID = requestID
        isRunning = true
        answer = ""
        errorMessage = nil
        evidenceHits = MeetingSearchIndex.search(trimmed, in: meetings, limit: 10)
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generationID == requestID {
                    self.isRunning = false
                    self.progressMessage = nil
                }
            }
            do {
                let generatedAnswer = try await MeetingAIService.answer(
                    question: trimmed,
                    meetings: meetings,
                    includeAllSegments: includeAllSegments,
                    progress: { message in
                        guard self.generationID == requestID else { return }
                        self.progressMessage = message
                    }
                )
                guard self.generationID == requestID else { return }
                answer = generatedAnswer
                if includeAllSegments {
                    evidenceHits = Self.citedEvidence(in: generatedAnswer, meetings: meetings)
                }
            } catch {
                guard self.generationID == requestID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func citedEvidence(
        in answer: String,
        meetings: [MeetingRecord]
    ) -> [MeetingSearchHit] {
        var hits: [MeetingSearchHit] = []
        for meeting in meetings {
            for segment in meeting.transcript where answer.contains(segment.id.uuidString) {
                hits.append(MeetingSearchHit(
                    meetingID: meeting.id,
                    segmentID: segment.id,
                    title: meeting.title,
                    excerpt: "\(segment.displaySpeaker): \(segment.text)",
                    score: 0
                ))
            }
            if answer.contains("[meeting:\(meeting.id.uuidString)]") {
                hits.append(MeetingSearchHit(
                    meetingID: meeting.id,
                    segmentID: nil,
                    title: meeting.title,
                    excerpt: meeting.rawNotes,
                    score: 0
                ))
            }
        }
        return Array(hits.prefix(12))
    }
}

private enum AIWorkspaceSource {
    case allMeetings([MeetingRecord])
    case dictation(TranscriptHistoryItem)
}

struct AllMeetingsWorkspace: View {
    @StateObject private var ai = TranscriptAIModel()
    @StateObject private var memory = MeetingMemoryModel()
    @State private var prompt = LibraryPromptCatalog.allMeetingsDefaultPrompt

    let meetings: [MeetingRecord]
    let onOpenEvidence: (UUID, UUID?) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask all meetings")
                    .font(.title3.weight(.semibold))
                Text(meetings.isEmpty
                    ? "Your saved meetings will become searchable here."
                    : "Search decisions, action items, and context across \(meetings.count) meeting\(meetings.count == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AIWorkspaceContent(
                source: .allMeetings(meetings),
                prompt: $prompt,
                ai: ai,
                memory: memory,
                showsEmptyResult: true,
                compact: false,
                onOpenEvidence: onOpenEvidence,
                onOpenSettings: onOpenSettings
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MeetingAskPanel: View {
    @StateObject private var ai = TranscriptAIModel()
    @StateObject private var memory = MeetingMemoryModel()
    @State private var isExpanded = false
    @State private var question = ""

    let meeting: MeetingRecord
    let onOpenEvidence: (UUID?) -> Void
    let onSummaryGenerated: (MeetingGeneratedNotes) -> Void
    let onSelectOutput: (String) -> Void
    let onOpenSettings: () -> Void

    init(
        meeting: MeetingRecord,
        onOpenEvidence: @escaping (UUID?) -> Void,
        onSummaryGenerated: @escaping (MeetingGeneratedNotes) -> Void,
        onSelectOutput: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.onOpenEvidence = onOpenEvidence
        self.onSummaryGenerated = onSummaryGenerated
        self.onSelectOutput = onSelectOutput
        self.onOpenSettings = onOpenSettings
        _isExpanded = State(initialValue: meeting.generatedNotes == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Ask this meeting")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    FeatureCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Text("Output")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Menu {
                                    ForEach(MeetingTemplateCatalog.builtIns) { template in
                                        Button {
                                            onSelectOutput(template.id)
                                        } label: {
                                            Label(template.name, systemImage: template.systemImage)
                                        }
                                    }
                                } label: {
                                    Label(output.name, systemImage: output.systemImage)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()

                                Button(memory.isRunning ? "Working…" : generationButtonTitle) {
                                    memory.generateSummary(
                                        for: meeting,
                                        completion: onSummaryGenerated
                                    )
                                }
                                .buttonStyle(.bordered)
                                .disabled(runIsDisabled)
                            }

                            Divider()

                            HStack(alignment: .bottom, spacing: 8) {
                                TextField("Ask a question about this meeting…", text: $question, axis: .vertical)
                                    .lineLimit(1...3)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(askQuestion)

                                Button(memory.isRunning ? "Working…" : "Ask") {
                                    askQuestion()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(askIsDisabled)
                            }

                            HStack(spacing: 7) {
                                Image(systemName: ai.isModelAvailable ? "checkmark.circle.fill" : "info.circle")
                                    .foregroundStyle(ai.isModelAvailable ? .green : .secondary)
                                Text(memory.progressMessage ?? ai.availabilityMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Button(action: onOpenSettings) {
                                    Image(systemName: "gearshape")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("AI settings")

                                Spacer()

                                if memory.isRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            if selectedProvider.sendsTranscriptOffDevice {
                                Text("This sends the meeting and your question to \(selectedProvider.displayName).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let errorMessage = memory.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    if !memory.answer.isEmpty {
                        FeatureCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Answer")
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Button("Copy", systemImage: "doc.on.clipboard") {
                                        let pasteboard = NSPasteboard.general
                                        pasteboard.clearContents()
                                        pasteboard.setString(memory.answer, forType: .string)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text(memory.answer)
                                    .font(.body)
                                    .textSelection(.enabled)

                                if !memory.evidenceHits.isEmpty {
                                    Divider()
                                    Text("Sources")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(memory.evidenceHits) { hit in
                                        Button {
                                            onOpenEvidence(hit.segmentID)
                                        } label: {
                                            Text(hit.excerpt)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
        .onAppear { ai.refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowAIProviderSettingsChanged)) { _ in
            ai.refreshAvailability()
        }
    }

    private var output: MeetingTemplate {
        MeetingTemplateCatalog.template(id: meeting.templateID)
    }

    private var generationButtonTitle: String {
        meeting.generatedNotes == nil ? "Generate" : "Regenerate"
    }

    private var selectedProvider: AIProviderKind { AIProviderSettings.shared.provider }

    private var hasContent: Bool {
        !meeting.transcript.isEmpty
            || !meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var runIsDisabled: Bool {
        memory.isRunning || !ai.isModelAvailable || meeting.transcript.isEmpty
    }

    private var askIsDisabled: Bool {
        memory.isRunning
            || !ai.isModelAvailable
            || !hasContent
            || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func askQuestion() {
        guard !askIsDisabled else { return }
        memory.ask(question: question, meetings: [meeting], includeAllSegments: true)
    }
}

struct DictationWorkspace: View {
    @StateObject private var ai = TranscriptAIModel()
    @StateObject private var memory = MeetingMemoryModel()
    @State private var isAskExpanded = false
    @State private var didCopy = false

    let item: TranscriptHistoryItem
    let onDelete: (TranscriptHistoryItem) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("\(item.dateDescription) · \(wordDescription(item.transcript))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button {
                    copyTranscript()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(item.transcript.isEmpty)
                .help(didCopy ? "Copied" : "Copy dictation")
                .accessibilityLabel(didCopy ? "Dictation copied" : "Copy dictation")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal dictation in Finder")
                Button(role: .destructive) {
                    onDelete(item)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete dictation")
                .accessibilityLabel("Delete dictation")
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let summary = item.generatedDescription {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Summary")
                                .font(.headline)
                            Text(summary)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }

                        Divider()
                    }

                    if let automaticOutput = item.automaticOutput {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Polished Dictation")
                                    .font(.headline)
                                Spacer()
                                Button("Copy polished text", systemImage: "doc.on.clipboard") {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(automaticOutput, forType: .string)
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(automaticOutput)
                                .font(.body)
                                .textSelection(.enabled)
                        }

                        Divider()
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Transcript")
                            .font(.headline)
                        Text(item.transcript.isEmpty ? "No transcript was saved." : item.transcript)
                            .font(.body)
                            .foregroundStyle(item.transcript.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(20)
            }

            Divider()

            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isAskExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                        Text("Work with this dictation")
                            .font(.callout.weight(.medium))
                        Text("Summarize, organize, or draft a follow-up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: isAskExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isAskExpanded {
                    Divider()
                    AIWorkspaceContent(
                        source: .dictation(item),
                        prompt: $ai.prompt,
                        ai: ai,
                        memory: memory,
                        showsEmptyResult: false,
                        compact: true,
                        onOpenEvidence: { _, _ in },
                        onOpenSettings: onOpenSettings
                    )
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
        }
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.transcript, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func wordDescription(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return "\(count) \(count == 1 ? "word" : "words")"
    }
}

private struct AIWorkspaceContent: View {
    let source: AIWorkspaceSource
    @Binding var prompt: String
    @ObservedObject var ai: TranscriptAIModel
    @ObservedObject var memory: MeetingMemoryModel
    @AppStorage("yaprflow.ai.output-preset") private var selectedItemPresetID = LibraryPromptCatalog.structuredBrief.id
    let showsEmptyResult: Bool
    let compact: Bool
    let onOpenEvidence: (UUID, UUID?) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureCard {
                promptSection
            }

            if let errorMessage = currentError {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if showsEmptyResult || !currentResult.isEmpty {
                FeatureCard {
                    resultSection
                }
                .frame(maxHeight: compact ? 220 : .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .onAppear {
            refreshSelectedItemPrompt()
            ai.refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowAIProviderSettingsChanged)) { _ in
            ai.refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowPromptPresetsChanged)) { _ in
            refreshSelectedItemPrompt()
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if source.isAllMeetings {
                HStack {
                    Text("Ask")
                        .font(.callout.weight(.medium))

                    Spacer()

                    Menu("Use preset") {
                        ForEach(currentPresets) { preset in
                            Button {
                                prompt = preset.prompt
                            } label: {
                                Label(preset.title, systemImage: preset.systemImage)
                            }
                        }

                        Divider()

                        Button("Reset") {
                            prompt = LibraryPromptCatalog.allMeetingsDefaultPrompt
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: compact ? 60 : 72, maxHeight: compact ? 76 : 92)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.separator, lineWidth: 1)
                    }
            } else {
                HStack(spacing: 12) {
                    Text("Output")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Menu {
                        ForEach(LibraryPromptCatalog.dictationPresets) { preset in
                            Button {
                                selectItemPreset(preset)
                            } label: {
                                Label(preset.title, systemImage: preset.systemImage)
                            }
                        }
                    } label: {
                        Label(selectedItemPreset.title, systemImage: selectedItemPreset.systemImage)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            HStack(spacing: 7) {
                Image(systemName: ai.isModelAvailable ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(ai.isModelAvailable ? .green : .secondary)
                Text(currentProgress ?? ai.availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("AI settings")

                Spacer()

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(isRunning ? "Working…" : runButtonTitle) {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(runIsDisabled)
            }

            if selectedProvider.sendsTranscriptOffDevice {
                Text("This sends the selected text and prompt to \(selectedProvider.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Result")
                    .font(.callout.weight(.medium))

                Spacer()

                Button("Copy", systemImage: "doc.on.clipboard") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(currentResult, forType: .string)
                }
                .buttonStyle(.plain)
                .disabled(currentResult.isEmpty)
            }

            if currentResult.isEmpty {
                ContentUnavailableView(
                    "Ask your meetings",
                    systemImage: "text.bubble",
                    description: Text(emptyResultDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: resultBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.separator, lineWidth: 1)
                    }

                if source.usesMeetingMemory && !memory.evidenceHits.isEmpty {
                    Divider()
                    Text("Sources")
                        .font(.headline)

                    ForEach(memory.evidenceHits) { hit in
                        Button {
                            onOpenEvidence(hit.meetingID, hit.segmentID)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title)
                                    .font(.callout.weight(.medium))
                                Text(hit.excerpt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func run() {
        switch source {
        case let .allMeetings(meetings):
            memory.ask(question: prompt, meetings: meetings)
        case let .dictation(item):
            ai.run(transcript: item.transcript)
        }
    }

    private var selectedProvider: AIProviderKind { AIProviderSettings.shared.provider }

    private var currentPresets: [LibraryPromptPreset] {
        source.isAllMeetings
            ? LibraryPromptCatalog.allMeetingPresets
            : LibraryPromptCatalog.dictationPresets
    }

    private var selectedItemPreset: LibraryPromptPreset {
        LibraryPromptCatalog.itemPreset(id: selectedItemPresetID)
    }

    private func selectItemPreset(_ preset: LibraryPromptPreset) {
        selectedItemPresetID = preset.id
        prompt = LibraryPromptPreferences.prompt(for: preset.id)
    }

    private func refreshSelectedItemPrompt() {
        guard !source.isAllMeetings else { return }
        let preset = LibraryPromptCatalog.itemPreset(id: selectedItemPresetID)
        if preset.id != selectedItemPresetID {
            selectedItemPresetID = preset.id
        }
        prompt = LibraryPromptPreferences.prompt(for: preset.id)
    }

    private var currentResult: String {
        source.usesMeetingMemory ? memory.answer : ai.result
    }

    private var currentError: String? {
        source.usesMeetingMemory ? memory.errorMessage : ai.errorMessage
    }

    private var currentProgress: String? {
        source.usesMeetingMemory ? memory.progressMessage : ai.processingMessage
    }

    private var isRunning: Bool {
        source.usesMeetingMemory ? memory.isRunning : ai.isRunning
    }

    private var runButtonTitle: String {
        source.isAllMeetings ? "Ask" : "Generate"
    }

    private var resultBinding: Binding<String> {
        source.usesMeetingMemory ? $memory.answer : $ai.result
    }

    private var runIsDisabled: Bool {
        isRunning
            || !ai.isModelAvailable
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !source.hasContent
    }

    private var emptyResultDescription: String {
        source.hasContent
            ? "Ask about decisions, action items, or anything discussed."
            : "Record a meeting to get started."
    }
}

private extension AIWorkspaceSource {
    var isAllMeetings: Bool {
        if case .allMeetings = self { return true }
        return false
    }

    var usesMeetingMemory: Bool {
        switch self {
        case .allMeetings: true
        case .dictation: false
        }
    }

    var hasContent: Bool {
        switch self {
        case let .allMeetings(meetings):
            !meetings.isEmpty
        case let .dictation(item):
            !item.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
