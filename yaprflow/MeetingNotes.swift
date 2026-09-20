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

struct MeetingNotesView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var calendar = CalendarMeetingService.shared
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
                        .frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
                    detail
                        .frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(minWidth: 940, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refresh()
            calendar.refreshIfAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowMeetingsChanged)) { _ in
            store.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("Meeting Notes", systemImage: "person.2.wave.2")
                .font(.title2.weight(.semibold))

            Picker("Mode", selection: $mode) {
                ForEach(MeetingNotesMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Spacer()

            if session.phase.isCapturing {
                Label(session.isPaused ? "Paused" : "Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(session.isPaused ? .orange : .red)
                    .font(.callout.weight(.semibold))
            }

            Button("New Meeting", systemImage: "plus") {
                session.prepare()
                showsLiveWorkspace = true
                    selectedMeetingID = nil
                    selectedEvidenceID = nil
                mode = .meetings
            }
            .disabled(session.phase.isCapturing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search meetings", text: $search)
                .textFieldStyle(.roundedBorder)

            calendarSection

            HStack {
                Text("Saved")
                    .font(.headline)
                Spacer()
                Text("\(filteredMeetings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(filteredMeetings, selection: $selectedMeetingID) { meeting in
                Button {
                    selectedMeetingID = meeting.id
                    selectedEvidenceID = nil
                    showsLiveWorkspace = false
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(meeting.generatedNotes?.overview ?? meeting.rawNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(meeting.id)
            }
            .listStyle(.sidebar)
        }
        .padding(14)
    }

    @ViewBuilder
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Upcoming")
                    .font(.headline)
                Spacer()
                if calendar.isLoading { ProgressView().controlSize(.small) }
                Button {
                    calendar.canReadCalendar
                        ? calendar.refreshIfAuthorized()
                        : calendar.requestAccessAndRefresh()
                } label: {
                    Image(systemName: calendar.canReadCalendar ? "arrow.clockwise" : "calendar.badge.plus")
                }
                .buttonStyle(.plain)
                .help(calendar.canReadCalendar ? "Refresh calendar" : "Connect calendar")
            }

            if !calendar.canReadCalendar {
                Button("Connect Apple Calendar") { calendar.requestAccessAndRefresh() }
                    .buttonStyle(.link)
            } else if calendar.meetings.isEmpty {
                Text("No meetings in the next seven days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendar.meetings.prefix(4)) { event in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).lineLimit(1)
                            Text(event.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") {
                            calendar.openJoinURL(for: event)
                            session.prepare(calendarMeeting: event)
                            showsLiveWorkspace = true
                            selectedMeetingID = nil
                            selectedEvidenceID = nil
                            session.start()
                        }
                        .controlSize(.small)
                        .disabled(session.phase.isCapturing)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
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

private struct LiveMeetingWorkspace: View {
    @ObservedObject var session: MeetingSessionController

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HSplitView {
                notesEditor
                    .frame(minWidth: 290, idealWidth: 360)
                transcript
                    .frame(minWidth: 340)
            }
            if session.meeting.generatedNotes != nil {
                Divider()
                GeneratedNotesView(meeting: session.meeting) { session.regenerateNotes() }
                    .frame(minHeight: 220, idealHeight: 280)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Meeting title", text: Binding(
                    get: { session.meeting.title },
                    set: session.updateTitle
                ))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))

                Spacer()

                Picker("Template", selection: Binding(
                    get: { session.meeting.templateID },
                    set: session.selectTemplate
                )) {
                    ForEach(MeetingTemplateCatalog.builtIns) { template in
                        Label(template.name, systemImage: template.systemImage).tag(template.id)
                    }
                }
                .frame(width: 180)

                Text(duration)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if session.phase.isCapturing {
                    Button(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill") {
                        session.togglePause()
                    }
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { session.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Start Meeting", systemImage: "record.circle") { session.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(
                        "I’m using Yaprflow to create a private transcript and notes for this meeting. Audio is not retained.",
                        forType: .string
                    )
                } label: {
                    Image(systemName: "person.badge.shield.checkmark")
                }
                .help("Copy recording disclosure")
            }

            statusLine
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.phase {
        case .idle:
            Label(meetingPrivacyMessage, systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        case let .preparing(message), let .finalizing(message):
            HStack { ProgressView().controlSize(.small); Text(message) }
                .foregroundStyle(.secondary)
        case .recording:
            Label("Recording microphone and Mac audio · visible indicator active", systemImage: "record.circle.fill")
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

    private var meetingPrivacyMessage: String {
        let settings = AIProviderSettings.shared
        if settings.provider == .appleIntelligence || !settings.isConfigured {
            return "Audio stays in memory only long enough to transcribe and is never saved."
        }
        return "Audio is never saved. At Stop, the transcript is sent directly to \(settings.provider.displayName) to generate notes."
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My notes")
                .font(.headline)
            Text("Your notes steer the generated result.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { session.meeting.rawNotes },
                set: session.updateRawNotes
            ))
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live transcript")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
        }
        .padding(16)
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

    init(initialMeeting: MeetingRecord, initialEvidenceID: UUID? = nil) {
        _meeting = State(initialValue: initialMeeting)
        _selectedEvidenceID = State(initialValue: initialEvidenceID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit", systemImage: "pencil") { isEditing = true }
                Button("Copy Markdown", systemImage: "doc.on.doc") { copyMarkdown() }
                Button("Reveal", systemImage: "folder") { reveal() }
            }
            .padding(16)
            Divider()

            HSplitView {
                GeneratedNotesView(meeting: meeting) { regenerate() } onEvidence: { id in
                    selectedEvidenceID = id
                }
                .frame(minWidth: 350)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(meeting.transcript) { segment in
                                TranscriptSegmentRow(
                                    segment: segment,
                                    isHighlighted: selectedEvidenceID == segment.id
                                )
                                .id(segment.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: selectedEvidenceID) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(minWidth: 350)
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
    }

    private func reveal() {
        guard let url = try? MeetingStore.shared.exportURL(for: meeting) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
                    Text("AI meeting notes").font(.headline)
                    Spacer()
                    Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
                        .controlSize(.small)
                }
                if let notes = meeting.generatedNotes {
                    Text(notes.overview)
                        .textSelection(.enabled)
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
                    Text("Finish the meeting to generate decisions, actions, and evidence-linked notes.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
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
        VStack(alignment: .leading, spacing: 16) {
            FeatureWindowHeader(
                symbolName: "sparkle.magnifyingglass",
                title: "Ask your meetings",
                subtitle: "Searches local meeting evidence, then answers with citations.",
                accent: .purple,
                badge: "Local index",
                badgeSymbol: "internaldrive"
            )

            FeatureCard {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("What did we decide about the launch?", text: $model.question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.ask(meetings: meetings) }
                    HStack {
                        Text(model.progressMessage ?? "\(meetings.count) meetings available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.isRunning { ProgressView().controlSize(.small) }
                        Button("Ask", systemImage: "arrow.up.circle.fill") {
                            model.ask(meetings: meetings)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                    }
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            FeatureCard {
                HSplitView {
                    ScrollView {
                        Text(model.answer.isEmpty ? "Answers will appear here with meeting and transcript-segment references." : model.answer)
                            .foregroundStyle(model.answer.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 12)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Evidence").font(.headline)
                        if model.evidenceHits.isEmpty {
                            Text("Relevant transcript passages appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.evidenceHits) { hit in
                                        Button {
                                            onOpenEvidence(hit.meetingID, hit.segmentID)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(hit.title).font(.caption.weight(.semibold))
                                                Text(hit.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(22)
    }
}

@MainActor
enum MeetingNotesWindowController {
    private static let window = FeatureWindowController(
        title: "Yaprflow Meeting Notes",
        contentSize: NSSize(width: 1100, height: 760),
        minimumSize: NSSize(width: 940, height: 680)
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
