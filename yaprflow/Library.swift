import AppKit
import Combine
import SwiftUI

@MainActor
private final class MeetingMemoryModel: ObservableObject {
    @Published private(set) var answer = ""
    @Published private(set) var isRunning = false
    @Published private(set) var progressMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var evidenceHits: [MeetingSearchHit] = []
    private var generationID = UUID()

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

    func clearOutput() {
        generationID = UUID()
        answer = ""
        isRunning = false
        progressMessage = nil
        errorMessage = nil
        evidenceHits = []
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

private enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case meetings = "Meetings"
    case dictations = "Dictations"
}

private enum LibrarySelection: Hashable {
    case allMeetings
    case meeting(UUID)
    case dictation(URL)
}

struct LibraryView: View {
    @ObservedObject private var appState = AppState.shared
    @StateObject private var ai = TranscriptAIModel()
    @StateObject private var memory = MeetingMemoryModel()
    @StateObject private var history = TranscriptHistoryModel()

    let meetings: [MeetingRecord]
    let onOpenEvidence: (UUID, UUID?) -> Void
    let onOpenSettings: () -> Void

    @State private var filter: LibraryFilter = .all
    @State private var selection: LibrarySelection = .allMeetings
    @State private var search = ""
    @State private var allMeetingsPrompt = LibraryPromptCatalog.allMeetingsDefaultPrompt

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider()

            HSplitView {
                sourceSidebar
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 300)

                workspace
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            ai.refreshAvailability()
            history.refresh()
            TranscriptMetadataEnricher.shared.enqueueMissingTranscripts()
        }
        .onChange(of: selection) { oldSelection, newSelection in
            if oldSelection != newSelection {
                ai.clearOutput()
                memory.clearOutput()
            }
            if case let .dictation(url) = newSelection {
                history.selection = url
            }
        }
        .onChange(of: appState.lastTranscript) { _, _ in
            history.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowTranscriptArchiveChanged)) { notification in
            if let change = notification.object as? TranscriptArchiveChange,
               selection == .dictation(change.oldURL) {
                selection = .dictation(change.newURL)
            }
            history.handleArchiveChange(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowAIProviderSettingsChanged)) { _ in
            ai.refreshAvailability()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            FeatureWindowHeader(
                symbolName: "books.vertical.fill",
                title: "Library",
                subtitle: "Ask across meetings or work with one saved item.",
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

    private var sourceSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Library filter", selection: $filter) {
                ForEach(LibraryFilter.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search library", text: $search)
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filter != .dictations {
                        if normalizedSearch.isEmpty {
                            sourceButton(selection: .allMeetings) {
                                HStack(spacing: 9) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.purple)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("All meetings")
                                            .font(.callout.weight(.medium))
                                        Text("Ask across \(meetings.count) saved meeting\(meetings.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if !filteredMeetings.isEmpty {
                            sectionLabel("Meetings")
                            ForEach(filteredMeetings) { meeting in
                                sourceButton(selection: .meeting(meeting.id)) {
                                    meetingRow(meeting)
                                }
                            }
                        }
                    }

                    if filter != .meetings, !filteredDictations.isEmpty {
                        sectionLabel("Dictations")
                        ForEach(filteredDictations) { item in
                            sourceButton(selection: .dictation(item.id)) {
                                dictationRow(item)
                            }
                        }
                    }

                    if hasNoSearchResults {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text("No matching items")
                                .font(.callout.weight(.medium))
                            Text("Try a different search.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            sourceActions
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func sourceButton<Content: View>(
        selection itemSelection: LibrarySelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            selection = itemSelection
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    selection == itemSelection ? Color.accentColor.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
    }

    private func meetingRow(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(meeting.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(meeting.startedAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(meetingPreview(meeting))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func dictationRow(_ item: TranscriptHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.recordedAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(item.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var sourceActions: some View {
        HStack(spacing: 8) {
            Button {
                history.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh library")

            Spacer()

            switch selection {
            case let .meeting(id):
                Button("Open Meeting") {
                    onOpenEvidence(id, nil)
                }
            case .dictation:
                Button {
                    history.revealSelection()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")

                Button("Open") {
                    history.openSelected()
                }

                Button("Copy", systemImage: "doc.on.clipboard") {
                    history.copySelected()
                }
                .disabled(history.selectedItem?.transcript.isEmpty != false)
            case .allMeetings:
                EmptyView()
            }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(sourceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                sourceKindLabel
            }

            FeatureCard {
                promptSection
            }

            if let errorMessage = currentError {
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

    private var sourceKindLabel: some View {
        Label(sourceKind, systemImage: sourceKindSymbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selection == .allMeetings ? "Ask" : "Prompt")
                    .font(.callout.weight(.medium))

                Spacer()

                Menu("Use preset") {
                    ForEach(currentPresets) { preset in
                        Button {
                            setCurrentPrompt(preset.prompt)
                        } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }

                    Divider()

                    Button("Reset") {
                        if selection == .allMeetings {
                            allMeetingsPrompt = LibraryPromptCatalog.allMeetingsDefaultPrompt
                        } else {
                            ai.resetPrompt()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            TextEditor(text: currentPromptBinding)
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
                Text(currentProgress ?? ai.availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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
                Text("This sends the selected source and prompt to \(selectedProvider.displayName).")
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
                    pasteboard.setString(currentResult, forType: .string)
                }
                .buttonStyle(.plain)
                .disabled(currentResult.isEmpty)
            }

            if currentResult.isEmpty {
                ContentUnavailableView(
                    emptyResultTitle,
                    systemImage: selection == .allMeetings ? "text.bubble" : "sparkles",
                    description: Text(emptyResultDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if usesMeetingMemory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(memory.answer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !memory.evidenceHits.isEmpty {
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
            } else {
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
        }
        .frame(maxHeight: .infinity)
    }

    private func run() {
        switch selection {
        case .allMeetings:
            memory.ask(question: allMeetingsPrompt, meetings: meetings)
        case let .meeting(id):
            guard let meeting = meetings.first(where: { $0.id == id }) else { return }
            memory.ask(question: ai.prompt, meetings: [meeting], includeAllSegments: true)
        case .dictation:
            ai.run(transcript: selectedSourceText)
        }
    }

    private var selectedProvider: AIProviderKind { AIProviderSettings.shared.provider }

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

    private var currentPresets: [LibraryPromptPreset] {
        selection == .allMeetings
            ? LibraryPromptCatalog.allMeetingPresets
            : LibraryPromptCatalog.itemPresets
    }

    private var currentResult: String {
        usesMeetingMemory ? memory.answer : ai.result
    }

    private var currentError: String? {
        usesMeetingMemory ? memory.errorMessage : ai.errorMessage
    }

    private var currentProgress: String? {
        usesMeetingMemory ? memory.progressMessage : ai.processingMessage
    }

    private var isRunning: Bool {
        usesMeetingMemory ? memory.isRunning : ai.isRunning
    }

    private var runButtonTitle: String {
        selection == .allMeetings ? "Ask" : "Run"
    }

    private var runIsDisabled: Bool {
        isRunning
            || !ai.isModelAvailable
            || currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (selection == .allMeetings ? meetings.isEmpty : selectedSourceText.isEmpty)
    }

    private var usesMeetingMemory: Bool {
        switch selection {
        case .allMeetings, .meeting: true
        case .dictation: false
        }
    }

    private var currentPrompt: String {
        selection == .allMeetings ? allMeetingsPrompt : ai.prompt
    }

    private var currentPromptBinding: Binding<String> {
        Binding(
            get: { currentPrompt },
            set: { setCurrentPrompt($0) }
        )
    }

    private func setCurrentPrompt(_ prompt: String) {
        if selection == .allMeetings {
            allMeetingsPrompt = prompt
        } else {
            ai.prompt = prompt
        }
    }

    private var sourceTitle: String {
        switch selection {
        case .allMeetings:
            "All meetings"
        case let .meeting(id):
            meetings.first { $0.id == id }?.title ?? "Meeting"
        case let .dictation(url):
            history.items.first { $0.id == url }?.title ?? "Dictation"
        }
    }

    private var sourceDescription: String {
        switch selection {
        case .allMeetings:
            return "Ask across \(meetings.count) saved meeting\(meetings.count == 1 ? "" : "s") with linked sources."
        case let .meeting(id):
            guard let meeting = meetings.first(where: { $0.id == id }) else { return "Meeting unavailable" }
            return "\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(wordDescription(selectedSourceText))"
        case let .dictation(url):
            guard let item = history.items.first(where: { $0.id == url }) else { return "Dictation unavailable" }
            return "\(item.dateDescription) · \(wordDescription(item.transcript))"
        }
    }

    private var sourceKind: String {
        switch selection {
        case .allMeetings: "Meeting memory"
        case .meeting: "Meeting"
        case .dictation: "Dictation"
        }
    }

    private var sourceKindSymbol: String {
        switch selection {
        case .allMeetings: "person.2.wave.2"
        case .meeting: "person.2"
        case .dictation: "waveform"
        }
    }

    private var selectedSourceText: String {
        switch selection {
        case .allMeetings:
            return ""
        case let .meeting(id):
            guard let meeting = meetings.first(where: { $0.id == id }) else { return "" }
            return meetingSource(meeting)
        case let .dictation(url):
            return history.items.first { $0.id == url }?.transcript ?? ""
        }
    }

    private func meetingSource(_ meeting: MeetingRecord) -> String {
        var sections: [String] = []
        if !meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Notes:\n\(meeting.rawNotes)")
        }
        if !meeting.plainTranscript.isEmpty {
            sections.append("Transcript:\n\(meeting.plainTranscript)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func wordDescription(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return "\(count) \(count == 1 ? "word" : "words")"
    }

    private func meetingPreview(_ meeting: MeetingRecord) -> String {
        if let overview = meeting.generatedNotes?.overview, !overview.isEmpty { return overview }
        if !meeting.rawNotes.isEmpty { return meeting.rawNotes }
        return meeting.transcript.first?.text ?? "No transcript"
    }

    private var filteredMeetings: [MeetingRecord] {
        let query = normalizedSearch
        guard !query.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.rawNotes.localizedCaseInsensitiveContains(query)
                || meeting.plainTranscript.localizedCaseInsensitiveContains(query)
                || meeting.generatedNotes?.overview.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var filteredDictations: [TranscriptHistoryItem] {
        let query = normalizedSearch
        guard !query.isEmpty else { return history.items }
        return history.items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.topic?.localizedCaseInsensitiveContains(query) == true
                || item.generatedDescription?.localizedCaseInsensitiveContains(query) == true
                || item.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasNoSearchResults: Bool {
        guard !normalizedSearch.isEmpty else { return false }
        return switch filter {
        case .all: filteredMeetings.isEmpty && filteredDictations.isEmpty
        case .meetings: filteredMeetings.isEmpty
        case .dictations: filteredDictations.isEmpty
        }
    }

    private var emptyResultTitle: String {
        selection == .allMeetings ? "Ask your meetings" : "Ready when you are"
    }

    private var emptyResultDescription: String {
        switch selection {
        case .allMeetings:
            meetings.isEmpty
                ? "Record a meeting to get started."
                : "Ask about decisions, action items, or anything discussed."
        case .meeting:
            "Use a preset or enter a prompt for this meeting."
        case .dictation:
            "Use a preset or enter a prompt for this dictation."
        }
    }
}
