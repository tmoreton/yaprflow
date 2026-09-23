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

    func ask(question: String, meeting: MeetingRecord) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
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
                let generatedAnswer = try await MeetingAIService.answer(
                    question: trimmed,
                    meeting: meeting,
                    progress: { message in
                        guard self.generationID == requestID else { return }
                        self.progressMessage = message
                    }
                )
                guard self.generationID == requestID else { return }
                answer = generatedAnswer
                evidenceHits = Self.citedEvidence(in: generatedAnswer, meeting: meeting)
            } catch {
                guard self.generationID == requestID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func citedEvidence(
        in answer: String,
        meeting: MeetingRecord
    ) -> [MeetingSearchHit] {
        var hits: [MeetingSearchHit] = []
        for segment in meeting.transcript where answer.contains(segment.id.uuidString) {
            hits.append(MeetingSearchHit(
                meetingID: meeting.id,
                segmentID: segment.id,
                title: meeting.title,
                excerpt: "\(segment.displaySpeaker): \(segment.text)"
            ))
        }
        if answer.contains("[meeting:\(meeting.id.uuidString)]") {
            hits.append(MeetingSearchHit(
                meetingID: meeting.id,
                segmentID: nil,
                title: meeting.title,
                excerpt: meeting.rawNotes
            ))
        }
        return Array(hits.prefix(12))
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
                    Text("Meeting tools")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
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
                        .accessibilityLabel("Notes format: \(output.name)")

                        Spacer(minLength: 8)

                        Button(memory.isRunning ? "Working…" : generationButtonTitle) {
                            memory.generateSummary(
                                for: meeting,
                                completion: onSummaryGenerated
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(runIsDisabled)
                    }

                    HStack(spacing: 8) {
                        TextField("Ask about this meeting…", text: $question, axis: .vertical)
                            .lineLimit(1...2)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(askQuestion)

                        Button(memory.isRunning ? "Working…" : "Ask") {
                            askQuestion()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(askIsDisabled)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: ai.isModelAvailable ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(ai.isModelAvailable ? .green : .secondary)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(statusMessage)

                        if memory.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer(minLength: 4)

                        Button(action: onOpenSettings) {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("AI settings")
                        .accessibilityLabel("AI settings")
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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

    private var statusMessage: String {
        if let progressMessage = memory.progressMessage { return progressMessage }
        guard ai.isModelAvailable else { return ai.availabilityMessage }
        return selectedProvider.sendsTranscriptOffDevice
            ? "\(selectedProvider.displayName) · sends meeting + question off-device"
            : "Apple Intelligence · on-device"
    }

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
        memory.ask(question: question, meeting: meeting)
    }
}

struct DictationWorkspace: View {
    @StateObject private var ai = TranscriptAIModel()
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
                        Image(systemName: isAskExpanded ? "chevron.down" : "chevron.right")
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
                    DictationAIWorkspace(
                        item: item,
                        prompt: $ai.prompt,
                        ai: ai,
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

private struct DictationAIWorkspace: View {
    let item: TranscriptHistoryItem
    @Binding var prompt: String
    @ObservedObject var ai: TranscriptAIModel
    @AppStorage("yaprflow.ai.output-preset") private var selectedItemPresetID = LibraryPromptCatalog.structuredBrief.id
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureCard {
                promptSection
            }

            if let errorMessage = ai.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !ai.result.isEmpty {
                FeatureCard {
                    resultSection
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

            HStack(spacing: 7) {
                Image(systemName: ai.isModelAvailable ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(ai.isModelAvailable ? .green : .secondary)
                Text(ai.processingMessage ?? ai.availabilityMessage)
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

                if ai.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(ai.isRunning ? "Working…" : "Generate") {
                    ai.run(transcript: item.transcript)
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

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .frame(minHeight: 110, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator, lineWidth: 1)
                }
        }
        .frame(maxHeight: .infinity)
    }

    private var selectedProvider: AIProviderKind { AIProviderSettings.shared.provider }

    private var selectedItemPreset: LibraryPromptPreset {
        LibraryPromptCatalog.itemPreset(id: selectedItemPresetID)
    }

    private func selectItemPreset(_ preset: LibraryPromptPreset) {
        selectedItemPresetID = preset.id
        prompt = LibraryPromptPreferences.prompt(for: preset.id)
    }

    private func refreshSelectedItemPrompt() {
        let preset = LibraryPromptCatalog.itemPreset(id: selectedItemPresetID)
        if preset.id != selectedItemPresetID {
            selectedItemPresetID = preset.id
        }
        prompt = LibraryPromptPreferences.prompt(for: preset.id)
    }

    private var runIsDisabled: Bool {
        ai.isRunning
            || !ai.isModelAvailable
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || item.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
