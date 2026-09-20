import AppKit
import Combine
import SwiftUI

@MainActor
private final class MeetingMemoryModel: ObservableObject {
    @Published var question = ""
    @Published private(set) var answer = ""
    @Published private(set) var isRunning = false
    @Published private(set) var progressMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var evidenceHits: [MeetingSearchHit] = []

    func ask(meetings: [MeetingRecord]) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        isRunning = true
        answer = ""
        errorMessage = nil
        evidenceHits = MeetingSearchIndex.search(trimmed, in: meetings, limit: 10)
        Task { [weak self] in
            guard let self else { return }
            defer {
                isRunning = false
                progressMessage = nil
            }
            do {
                answer = try await MeetingAIService.answer(
                    question: trimmed,
                    meetings: meetings,
                    progress: { message in self.progressMessage = message }
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum MeetingNotesMode: String, CaseIterable {
    case meetings = "Meetings"
    case ask = "Ask"
}

private enum MeetingWorkspaceSection: String, CaseIterable {
    case capture = "Notes & transcript"
    case summary = "Summary"
}

struct MeetingNotesView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var session = MeetingSessionController.shared
    @StateObject private var memory = MeetingMemoryModel()
    @State private var mode: MeetingNotesMode = .meetings
    @State private var search = ""
    @State private var selectedMeetingID: UUID?
    @State private var selectedEvidenceID: UUID?
    @State private var showsLiveWorkspace = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch mode {
            case .meetings:
                HSplitView {
                    sidebar
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)
                    detail
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            case .ask:
                MeetingMemoryView(model: memory, meetings: store.meetings) { meetingID, segmentID in
                    selectedMeetingID = meetingID
                    selectedEvidenceID = segmentID
                    showsLiveWorkspace = false
                    mode = .meetings
                }
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowMeetingsChanged)) { _ in
            store.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Meeting Notes")
                .font(.title2.weight(.semibold))

            Picker("Meeting Notes section", selection: $mode) {
                ForEach(MeetingNotesMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()

            if session.phase.isCapturing {
                Label(session.isPaused ? "Paused" : "Recording", systemImage: "circle.fill")
                    .foregroundStyle(session.isPaused ? .orange : .red)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel(session.isPaused ? "Meeting capture paused" : "Meeting capture recording")
            }

            Button("New", systemImage: "plus") {
                session.prepare()
                showsLiveWorkspace = true
                selectedMeetingID = nil
                selectedEvidenceID = nil
                mode = .meetings
            }
            .disabled(session.phase.isCapturing)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("New meeting (Shift-Command-N)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search meetings", text: $search)
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
                Text("Meetings")
                    .font(.headline)
                Spacer()
                Text(search.isEmpty ? "\(store.meetings.count)" : "\(filteredMeetings.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredMeetings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: search.isEmpty ? "person.2.wave.2" : "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "Your saved meetings will appear here." : "No meetings match your search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredMeetings) { meeting in
                            Button {
                                selectedMeetingID = meeting.id
                                selectedEvidenceID = nil
                                showsLiveWorkspace = false
                            } label: {
                                SavedMeetingRow(
                                    meeting: meeting,
                                    isSelected: !showsLiveWorkspace && selectedMeetingID == meeting.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(meeting.title)")
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private var detail: some View {
        if showsLiveWorkspace {
            LiveMeetingWorkspace(session: session)
        } else if let id = selectedMeetingID, let meeting = store.meeting(id: id) {
            SavedMeetingView(initialMeeting: meeting, initialEvidenceID: selectedEvidenceID)
                .id("\(meeting.id.uuidString)-\(selectedEvidenceID?.uuidString ?? "none")")
        } else {
            ContentUnavailableView(
                "Choose a meeting",
                systemImage: "person.2.wave.2",
                description: Text("Select a saved meeting or start a new one.")
            )
        }
    }

    private var filteredMeetings: [MeetingRecord] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.meetings }
        let ids = Set(MeetingSearchIndex.search(trimmed, in: store.meetings).map(\.meetingID))
        return store.meetings.filter { ids.contains($0.id) }
    }
}

private struct SavedMeetingRow: View {
    let meeting: MeetingRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meeting.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }

    private var preview: String {
        let value = meeting.generatedNotes?.overview ?? meeting.rawNotes
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No notes yet"
            : value
    }
}

private struct LiveMeetingWorkspace: View {
    @ObservedObject var session: MeetingSessionController
    @State private var section: MeetingWorkspaceSection = .capture

    var body: some View {
        VStack(spacing: 0) {
            controls

            if session.meeting.generatedNotes != nil {
                Divider()
                Picker("Meeting workspace", selection: $section) {
                    ForEach(MeetingWorkspaceSection.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
                .padding(.vertical, 10)
            }

            Divider()

            switch section {
            case .capture:
                captureWorkspace
            case .summary:
                GeneratedNotesView(meeting: session.meeting) { session.regenerateNotes() }
                    .padding(16)
                .frame(maxHeight: .infinity)
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .complete, session.meeting.generatedNotes != nil {
                section = .summary
            }
        }
        .onChange(of: session.meeting.id) { _, _ in
            section = .capture
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                TextField("Meeting title", text: Binding(
                    get: { session.meeting.title },
                    set: session.updateTitle
                ))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .accessibilityLabel("Meeting title")

                Spacer(minLength: 12)

                Text(duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Meeting duration \(duration)")

                if session.phase.isCapturing {
                    Button(session.isPaused ? "Resume" : "Pause") {
                        session.togglePause()
                    }
                    Button("Stop", role: .destructive) { session.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button("Start") { session.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }

            HStack(spacing: 10) {
                Picker("Template", selection: Binding(
                    get: { session.meeting.templateID },
                    set: session.selectTemplate
                )) {
                    ForEach(MeetingTemplateCatalog.builtIns) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
                .help("Meeting notes template")

                Spacer()

                Label("Audio isn’t saved", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusLine
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    private var captureWorkspace: some View {
        HSplitView {
            notesEditor
                .padding(16)
            .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)

            transcript
                .padding(16)
            .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.phase {
        case .idle:
            EmptyView()
        case let .preparing(message), let .finalizing(message):
            HStack { ProgressView().controlSize(.small); Text(message) }
                .foregroundStyle(.secondary)
        case .recording:
            Label("Recording microphone and Mac audio", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        case .paused:
            Label("Capture paused", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .complete:
            Label("Transcript and meeting notes saved locally", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            ZStack(alignment: .topLeading) {
                if session.meeting.rawNotes.isEmpty {
                    Text("Add notes…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { session.meeting.rawNotes },
                    set: session.updateRawNotes
                ))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .accessibilityLabel("My meeting notes")
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            if hasTranscript {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(session.meeting.transcript) { TranscriptSegmentRow(segment: $0) }
                        if !session.liveThem.isEmpty {
                            TranscriptSegmentRow(segment: MeetingTranscriptSegment(
                                speaker: .them,
                                startTime: session.elapsed,
                                endTime: session.elapsed,
                                text: session.liveThem
                            ), isLive: true)
                        }
                        if !session.liveMe.isEmpty {
                            TranscriptSegmentRow(segment: MeetingTranscriptSegment(
                                speaker: .me,
                                startTime: session.elapsed,
                                endTime: session.elapsed,
                                text: session.liveMe
                            ), isLive: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Transcript appears here")
                        .font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    private var hasTranscript: Bool {
        !session.meeting.transcript.isEmpty || !session.liveMe.isEmpty || !session.liveThem.isEmpty
    }

    private var isBusy: Bool {
        if case .preparing = session.phase { return true }
        if case .finalizing = session.phase { return true }
        return false
    }

    private var duration: String {
        let seconds = Int(session.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SavedMeetingView: View {
    @State private var meeting: MeetingRecord
    @State private var selectedEvidenceID: UUID?
    @State private var isEditing = false
    @State private var didCopy = false

    init(initialMeeting: MeetingRecord, initialEvidenceID: UUID? = nil) {
        _meeting = State(initialValue: initialMeeting)
        _selectedEvidenceID = State(initialValue: initialEvidenceID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                        if let endedAt = meeting.endedAt {
                            Text("·")
                            Text(duration(until: endedAt))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Edit", systemImage: "pencil") { isEditing = true }
                Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    copyMarkdown()
                }
                Button {
                    reveal()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal meeting in Finder")
            }
            .padding(16)

            Divider()

            HSplitView {
                GeneratedNotesView(meeting: meeting) { regenerate() } onEvidence: { id in
                    selectedEvidenceID = id
                }
                .padding(16)
                .frame(minWidth: 330, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcript")
                        .font(.headline)

                    if meeting.transcript.isEmpty {
                        ContentUnavailableView("No transcript", systemImage: "waveform.slash")
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 7) {
                                    ForEach(meeting.transcript) { segment in
                                        TranscriptSegmentRow(
                                            segment: segment,
                                            isHighlighted: selectedEvidenceID == segment.id
                                        )
                                        .id(segment.id)
                                    }
                                }
                            }
                            .onChange(of: selectedEvidenceID) { _, id in
                                guard let id else { return }
                                withAnimation { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(minWidth: 330, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $isEditing) {
            SavedMeetingEditor(meeting: $meeting) {
                _ = try? MeetingStore.shared.save(meeting)
                isEditing = false
            }
        }
    }

    private func regenerate() {
        Task {
            if let notes = try? await MeetingAIService.generateNotes(for: meeting, progress: { _ in }) {
                meeting.generatedNotes = notes
                _ = try? MeetingStore.shared.save(meeting)
            }
        }
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MeetingMarkdownRenderer.render(meeting), forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func reveal() {
        guard let url = try? MeetingStore.shared.exportURL(for: meeting) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func duration(until endDate: Date) -> String {
        let totalSeconds = max(0, Int(endDate.timeIntervalSince(meeting.startedAt)))
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }
}

private struct SavedMeetingEditor: View {
    @Binding var meeting: MeetingRecord
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit meeting notes").font(.title2.weight(.semibold))
            TextField("Meeting title", text: $meeting.title)
            Text("Overview").font(.headline)
            TextEditor(text: Binding(
                get: { meeting.generatedNotes?.overview ?? "" },
                set: { meeting.generatedNotes?.overview = $0 }
            ))
            .frame(minHeight: 80)
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator) }

            if let notes = meeting.generatedNotes {
                Text("Structured notes").font(.headline)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(notes.insights.indices, id: \.self) { index in
                            HStack {
                                Text(notes.insights[index].kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                TextField("Note", text: Binding(
                                    get: { meeting.generatedNotes?.insights[index].text ?? "" },
                                    set: { meeting.generatedNotes?.insights[index].text = $0 }
                                ))
                            }
                        }
                    }
                }
            }

            Text("My notes").font(.headline)
            TextEditor(text: $meeting.rawNotes)
                .frame(minHeight: 90)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: onSave).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 620, height: 590)
    }
}

private struct GeneratedNotesView: View {
    let meeting: MeetingRecord
    let onRegenerate: () -> Void
    var onEvidence: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meeting summary")
                            .font(.headline)
                        Text(MeetingTemplateCatalog.template(id: meeting.templateID).name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
                        .controlSize(.small)
                        .disabled(meeting.transcript.isEmpty)
                }
                if let notes = meeting.generatedNotes {
                    Text(notes.overview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    ForEach(MeetingInsightKind.allCases, id: \.self) { kind in
                        let items = notes.insights.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Text(kind.displayName).font(.headline)
                            ForEach(items) { insight in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Image(systemName: kind == .actionItem ? "checkmark.circle" : "circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(insight.text).textSelection(.enabled)
                                        if insight.owner != nil || insight.dueDate != nil {
                                            Text([insight.owner.map { "Owner: \($0)" }, insight.dueDate.map { "Due: \($0)" }]
                                                .compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let evidence = insight.citationSegmentIDs.first {
                                        Button { onEvidence(evidence) } label: {
                                            Image(systemName: "text.magnifyingglass")
                                        }
                                        .buttonStyle(.plain)
                                        .help("Show transcript evidence")
                                    }
                                }
                            }
                        }
                    }
                    if !notes.followUpEmail.isEmpty {
                        Text("Follow-up email").font(.headline)
                        Text(notes.followUpEmail)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: meeting.transcript.isEmpty ? "sparkles" : "sparkles.rectangle.stack")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(meeting.transcript.isEmpty ? "Summary appears after the meeting" : "No summary generated yet")
                            .font(.callout.weight(.medium))
                        Text(meeting.transcript.isEmpty
                            ? "Yaprflow turns the transcript and your notes into decisions, actions, and evidence-linked notes."
                            : "Use Regenerate after configuring an AI provider in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptSegmentRow: View {
    let segment: MeetingTranscriptSegment
    var isLive = false
    var isHighlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.displaySpeaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .me ? .blue : .purple)
                Text(segment.text)
                    .foregroundStyle(isLive ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var timestamp: String {
        let seconds = Int(segment.startTime)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MeetingMemoryView: View {
    @ObservedObject var model: MeetingMemoryModel
    let meetings: [MeetingRecord]
    let onOpenEvidence: (UUID, UUID?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Ask about your meetings", text: $model.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.ask(meetings: meetings) }
                    .accessibilityLabel("Ask your meetings")

                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Ask") {
                    model.ask(meetings: meetings)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    meetings.isEmpty
                        || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isRunning
                )
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if model.answer.isEmpty {
                        ContentUnavailableView(
                            meetings.isEmpty ? "No saved meetings" : "Ask anything",
                            systemImage: meetings.isEmpty ? "person.2.slash" : "text.bubble",
                            description: Text(
                                meetings.isEmpty
                                    ? "Record a meeting to get started."
                                    : "Search decisions, action items, or anything discussed."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        Text(model.answer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !model.evidenceHits.isEmpty {
                            Divider()
                            Text("Sources")
                                .font(.headline)

                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(model.evidenceHits) { hit in
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
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open evidence from \(hit.title)")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(20)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
enum MeetingNotesWindowController {
    private static let window = FeatureWindowController(
        title: "Yaprflow Meeting Notes",
        contentSize: NSSize(width: 980, height: 680),
        minimumSize: NSSize(width: 820, height: 580)
    ) {
        MeetingNotesView()
    }

    static func show(calendarMeeting: CalendarMeeting? = nil) {
        if let calendarMeeting {
            MeetingSessionController.shared.prepare(calendarMeeting: calendarMeeting)
        }
        window.show()
    }

    static var isVisibleForSmokeTest: Bool { window.isVisibleForSmokeTest }
}
