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
        VStack(alignment: .leading, spacing: 14) {
            FeatureWindowHeader(
                symbolName: "person.2.wave.2",
                title: "Meeting Notes",
                subtitle: "Private live transcription, structured notes, and searchable meeting memory.",
                accent: .blue,
                badge: "Audio not saved",
                badgeSymbol: "lock.fill"
            )

            HStack(spacing: 12) {
                Picker("Meeting Notes section", selection: $mode) {
                    ForEach(MeetingNotesMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)

                Spacer()

                if session.phase.isCapturing {
                    Label(session.isPaused ? "Paused" : "Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(session.isPaused ? .orange : .red)
                        .font(.callout.weight(.semibold))
                        .accessibilityLabel(session.isPaused ? "Meeting capture paused" : "Meeting capture recording")
                }

                Button("New Meeting", systemImage: "plus") {
                    session.prepare()
                    showsLiveWorkspace = true
                    selectedMeetingID = nil
                    selectedEvidenceID = nil
                    mode = .meetings
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.phase.isCapturing)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Prepare a new meeting (Shift-Command-N)")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
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

            calendarSection

            HStack {
                Text("Saved")
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
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
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
                Text("Add your upcoming meetings for one-click setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect Apple Calendar") { calendar.requestAccessAndRefresh() }
                    .buttonStyle(.link)
            } else if calendar.meetings.isEmpty {
                Text("No meetings in the next seven days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendar.meetings.prefix(3)) { event in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(event.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(event.joinURL == nil ? "Use" : "Join") {
                            session.prepare(calendarMeeting: event)
                            showsLiveWorkspace = true
                            selectedMeetingID = nil
                            selectedEvidenceID = nil
                            if event.joinURL != nil {
                                calendar.openJoinURL(for: event)
                            }
                        }
                        .controlSize(.small)
                        .disabled(session.phase.isCapturing)
                        .help(event.joinURL == nil
                            ? "Prepare this meeting"
                            : "Open the meeting link and prepare notes")
                    }
                }
            }

            if let error = calendar.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
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
    @State private var disclosureCopied = false

    var body: some View {
        VStack(spacing: 14) {
            controls

            if session.meeting.generatedNotes != nil {
                Picker("Meeting workspace", selection: $section) {
                    ForEach(MeetingWorkspaceSection.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
            }

            switch section {
            case .capture:
                captureWorkspace
            case .summary:
                FeatureCard {
                    GeneratedNotesView(meeting: session.meeting) { session.regenerateNotes() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .onChange(of: session.phase) { _, phase in
            if phase == .complete, session.meeting.generatedNotes != nil {
                section = .summary
            }
        }
        .onChange(of: session.meeting.id) { _, _ in
            section = .capture
            disclosureCopied = false
        }
    }

    private var controls: some View {
        FeatureCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Meeting title", text: Binding(
                        get: { session.meeting.title },
                        set: session.updateTitle
                    ))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .accessibilityLabel("Meeting title")

                    Spacer(minLength: 12)

                    Label(duration, systemImage: "timer")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Meeting duration \(duration)")
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Template")
                        .font(.callout.weight(.medium))
                    Picker("Template", selection: Binding(
                        get: { session.meeting.templateID },
                        set: session.selectTemplate
                    )) {
                        ForEach(MeetingTemplateCatalog.builtIns) { template in
                            Label(template.name, systemImage: template.systemImage).tag(template.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .help("Choose how Yaprflow structures the final notes")

                    Spacer(minLength: 8)

                    Button(disclosureCopied ? "Copied" : "Disclosure", systemImage: disclosureCopied ? "checkmark" : "person.badge.shield.checkmark") {
                        copyDisclosure()
                    }
                    .help("Copy a short recording disclosure")

                    if session.phase.isCapturing {
                        Button(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill") {
                            session.togglePause()
                        }
                        Button("Stop", systemImage: "stop.fill", role: .destructive) { session.stop() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .keyboardShortcut(.return, modifiers: [.command])
                    } else {
                        Button("Start Meeting", systemImage: "record.circle") { session.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }

                statusLine
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var captureWorkspace: some View {
        HSplitView {
            FeatureCard {
                notesEditor
            }
            .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)

            FeatureCard {
                transcript
            }
            .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
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
            HStack(alignment: .firstTextBaseline) {
                Text("My notes")
                    .font(.headline)
                Spacer()
                Text("Shapes the summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if session.meeting.rawNotes.isEmpty {
                    Text("Capture context, ideas, and details you don’t want to lose…")
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
            HStack(alignment: .firstTextBaseline) {
                Text("Live transcript")
                    .font(.headline)
                Spacer()
                speakerKey
            }

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
                    Text("The conversation will appear here")
                        .font(.callout.weight(.medium))
                    Text("Yaprflow labels your microphone as Me and Mac audio as Them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    private var speakerKey: some View {
        HStack(spacing: 8) {
            Label("Me", systemImage: "circle.fill")
                .foregroundStyle(.blue)
            Label("Them", systemImage: "circle.fill")
                .foregroundStyle(.purple)
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Speaker colors: Me is blue, Them is purple")
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

    private func copyDisclosure() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            "I’m using Yaprflow to create a private transcript and notes for this meeting. Audio is not retained.",
            forType: .string
        )
        disclosureCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            disclosureCopied = false
        }
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
        VStack(spacing: 14) {
            FeatureCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                            if let endedAt = meeting.endedAt {
                                Text("·")
                                Text(duration(until: endedAt))
                            }
                            Label("Saved locally", systemImage: "internaldrive")
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
                    .help("Reveal the Markdown file in Finder")
                    .accessibilityLabel("Reveal meeting in Finder")
                }
            }

            HSplitView {
                FeatureCard {
                    GeneratedNotesView(meeting: meeting) { regenerate() } onEvidence: { id in
                        selectedEvidenceID = id
                    }
                }
                .frame(minWidth: 330, maxHeight: .infinity)

                FeatureCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Transcript")
                                .font(.headline)
                            Spacer()
                            Text("\(meeting.transcript.count) segments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if meeting.transcript.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform.slash")
                                    .font(.title2)
                                    .foregroundStyle(.tertiary)
                                Text("No transcript was captured")
                                    .font(.callout.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                }
                .frame(minWidth: 330, maxHeight: .infinity)
            }
        }
        .padding(16)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask your meetings")
                        .font(.title3.weight(.semibold))
                    Text("Searches local meeting evidence, then answers with citations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Local index", systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            FeatureCard {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("What did we decide about the launch?", text: $model.question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.ask(meetings: meetings) }
                        .accessibilityLabel("Ask your meetings")

                    if model.question.isEmpty, !meetings.isEmpty {
                        HStack(spacing: 7) {
                            suggestion("What decisions did we make?")
                            suggestion("What are my open action items?")
                            suggestion("Summarize the latest meeting")
                        }
                    }

                    HStack {
                        Text(model.progressMessage ?? availabilityMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.isRunning { ProgressView().controlSize(.small) }
                        Button("Ask", systemImage: "arrow.up.circle.fill") {
                            model.ask(meetings: meetings)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            meetings.isEmpty
                                || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isRunning
                        )
                    }
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            FeatureCard {
                HSplitView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Answer").font(.headline)
                        ScrollView {
                            if model.answer.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: meetings.isEmpty ? "person.2.slash" : "text.bubble")
                                        .font(.title2)
                                        .foregroundStyle(.tertiary)
                                    Text(meetings.isEmpty ? "No saved meetings yet" : "Ask across every saved meeting")
                                        .font(.callout.weight(.medium))
                                    Text(meetings.isEmpty
                                        ? "Record a meeting, then return here to search it."
                                        : "Answers include the transcript passages used as evidence.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                            } else {
                                Text(model.answer)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
                                            .padding(8)
                                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Open evidence from \(hit.title)")
                                    }
                                }
                            }
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var availabilityMessage: String {
        meetings.isEmpty ? "Record a meeting to get started" : "\(meetings.count) meetings available"
    }

    private func suggestion(_ title: String) -> some View {
        Button(title) {
            model.question = title
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
