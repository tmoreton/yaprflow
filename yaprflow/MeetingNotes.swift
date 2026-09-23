import AppKit
import Combine
import SwiftUI

enum MeetingWorkspaceSelection: Hashable {
    case liveMeeting
    case meeting(UUID)
    case dictation(URL)
}

private enum WorkspaceDeletionTarget {
    case meeting(MeetingRecord)
    case dictation(TranscriptHistoryItem)
}

private enum LibrarySidebarItem: Identifiable {
    case meeting(MeetingRecord)
    case dictation(TranscriptHistoryItem)

    var id: MeetingWorkspaceSelection {
        switch self {
        case let .meeting(meeting): .meeting(meeting.id)
        case let .dictation(dictation): .dictation(dictation.id)
        }
    }

    var recordedAt: Date {
        switch self {
        case let .meeting(meeting): meeting.startedAt
        case let .dictation(dictation): dictation.recordedAt
        }
    }
}

@MainActor
private final class MeetingNotesNavigation: ObservableObject {
    static let shared = MeetingNotesNavigation()
    @Published var selection: MeetingWorkspaceSelection = .liveMeeting
}

struct MeetingNotesView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var session = MeetingSessionController.shared
    @ObservedObject private var navigation = MeetingNotesNavigation.shared
    @StateObject private var history = TranscriptHistoryModel()
    @State private var search = ""
    @State private var pendingDeletion: WorkspaceDeletionTarget?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
                detail
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refresh()
            history.refresh()
            TranscriptMetadataEnricher.shared.enqueueMissingTranscripts()
            Telemetry.shared.track(.featureOpened(.meetingNotes))
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowMeetingsChanged)) { _ in
            store.refresh()
        }
        .onChange(of: appState.lastTranscript) { _, _ in
            history.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowTranscriptArchiveChanged)) { notification in
            if let change = notification.object as? TranscriptArchiveChange,
               navigation.selection == .dictation(change.oldURL) {
                navigation.selection = .dictation(change.newURL)
            }
            history.refresh()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            if let pendingDeletion {
                switch pendingDeletion {
                case let .meeting(meeting):
                    Button("Delete Meeting", role: .destructive) {
                        delete(meeting)
                    }
                case let .dictation(item):
                    Button("Delete Dictation", role: .destructive) {
                        delete(item)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(deletionMessage)
        }
        .alert(
            "Couldn’t update library",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { clearDeletionError() } }
            )
        ) {
            Button("OK") { clearDeletionError() }
        } message: {
            Text(deletionErrorMessage ?? "Please try again.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Spacer()

            Button("New Meeting", systemImage: "plus") { startNewMeeting() }
                .disabled(session.phase.isCapturing)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New meeting (Shift-Command-N)")

            Button {
                SettingsWindowController.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (Command-,)")
            .accessibilityLabel("Open Settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library")
                .font(.headline)
                .padding(.horizontal, 3)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search library", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search meetings and dictations")
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
                    if showsCurrentMeeting {
                        sectionHeader("Current")
                        sourceButton(selection: .liveMeeting) {
                            MeetingSidebarRow(
                                meeting: session.meeting,
                                activity: currentMeetingActivity
                            )
                        }
                        .accessibilityLabel("Open current meeting, \(session.meeting.title)")
                    }

                    if !recentItems.isEmpty {
                        sectionHeader("Recent")
                        ForEach(recentItems) { item in
                            switch item {
                            case let .meeting(meeting):
                                sourceButton(selection: item.id) {
                                    MeetingSidebarRow(meeting: meeting)
                                }
                                .accessibilityLabel("Open meeting, \(meeting.title)")
                                .contextMenu {
                                    Button("Delete Meeting", systemImage: "trash", role: .destructive) {
                                        pendingDeletion = .meeting(meeting)
                                    }
                                }
                            case let .dictation(dictation):
                                sourceButton(selection: item.id) {
                                    DictationRow(item: dictation)
                                }
                                .accessibilityLabel("Open dictation, \(dictation.title)")
                                .contextMenu {
                                    Button("Copy Transcript", systemImage: "doc.on.clipboard") {
                                        copyDictation(dictation)
                                    }
                                    Button("Reveal in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([dictation.url])
                                    }
                                    Divider()
                                    Button("Delete Dictation", systemImage: "trash", role: .destructive) {
                                        pendingDeletion = .dictation(dictation)
                                    }
                                }
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
                    } else if normalizedSearch.isEmpty
                                && !showsCurrentMeeting
                                && store.meetings.isEmpty
                                && history.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text("Your meetings and dictations will appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func sourceButton<Content: View>(
        selection: MeetingWorkspaceSelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            navigation.selection = selection
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    navigation.selection == selection ? Color.accentColor.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .liveMeeting:
            LiveMeetingWorkspace(
                session: session,
                onOpenSettings: { SettingsWindowController.show() }
            )
        case let .meeting(id):
            if let meeting = store.meeting(id: id) {
                SavedMeetingView(
                    initialMeeting: meeting,
                    onDelete: { pendingDeletion = .meeting($0) },
                    onOpenSettings: { SettingsWindowController.show() }
                )
                .id(meeting.id)
            } else {
                ContentUnavailableView(
                    "Meeting unavailable",
                    systemImage: "person.2.slash",
                    description: Text("Choose another meeting from the sidebar.")
                )
            }
        case let .dictation(url):
            if let item = history.items.first(where: { $0.id == url }) {
                DictationWorkspace(
                    item: item,
                    onDelete: { pendingDeletion = .dictation($0) },
                    onOpenSettings: { SettingsWindowController.show() }
                )
                .id(item.id)
            } else {
                ContentUnavailableView(
                    "Dictation unavailable",
                    systemImage: "waveform.slash",
                    description: Text("Choose another dictation from the sidebar.")
                )
            }
        }
    }

    private func startNewMeeting() {
        session.prepare()
        navigation.selection = .liveMeeting
    }

    private var filteredMeetings: [MeetingRecord] {
        let query = normalizedSearch
        let savedMeetings = store.meetings.filter { $0.id != session.meeting.id }
        guard !query.isEmpty else { return savedMeetings }
        return savedMeetings.filter { meeting in
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

    private var recentItems: [LibrarySidebarItem] {
        (filteredMeetings.map(LibrarySidebarItem.meeting)
            + filteredDictations.map(LibrarySidebarItem.dictation))
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsCurrentMeeting: Bool {
        hasCurrentMeeting && (normalizedSearch.isEmpty || currentMeetingMatchesSearch)
    }

    private var hasCurrentMeeting: Bool {
        session.phase != .idle
            || session.meeting.endedAt != nil
            || !session.meeting.transcript.isEmpty
            || !session.meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.meeting.title != "New meeting"
    }

    private var currentMeetingMatchesSearch: Bool {
        let query = normalizedSearch
        guard !query.isEmpty else { return true }
        return session.meeting.title.localizedCaseInsensitiveContains(query)
            || session.meeting.rawNotes.localizedCaseInsensitiveContains(query)
            || session.meeting.plainTranscript.localizedCaseInsensitiveContains(query)
            || session.meeting.generatedNotes?.overview.localizedCaseInsensitiveContains(query) == true
    }

    private var currentMeetingActivity: MeetingSidebarActivity? {
        switch session.phase {
        case .preparing:
            .preparing
        case .recording:
            .recording
        case .paused:
            .paused
        case .finalizing:
            .finishing
        case .complete, .failed, .idle:
            nil
        }
    }

    private var hasNoSearchResults: Bool {
        !normalizedSearch.isEmpty
            && !showsCurrentMeeting
            && filteredMeetings.isEmpty
            && filteredDictations.isEmpty
    }

    private func copyDictation(_ item: TranscriptHistoryItem) {
        guard !item.transcript.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.transcript, forType: .string)
    }

    private func delete(_ meeting: MeetingRecord) {
        pendingDeletion = nil
        guard store.delete(meeting) else { return }
        if navigation.selection == .meeting(meeting.id) {
            navigation.selection = .liveMeeting
        }
    }

    private func delete(_ item: TranscriptHistoryItem) {
        pendingDeletion = nil
        guard history.delete(item) else { return }
        if navigation.selection == .dictation(item.id) {
            navigation.selection = .liveMeeting
        }
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .meeting: "Delete this meeting?"
        case .dictation: "Delete this dictation?"
        case nil: "Delete this item?"
        }
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .meeting:
            "The transcript, notes, and summary will be moved to the Trash."
        case .dictation:
            "The transcript will be moved to the Trash."
        case nil:
            "This item will be moved to the Trash."
        }
    }

    private var deletionErrorMessage: String? {
        store.errorMessage ?? history.errorMessage
    }

    private func clearDeletionError() {
        store.clearError()
        history.clearError()
    }
}

private struct DictationRow: View {
    let item: TranscriptHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            sidebarIcon("waveform", color: .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.recordedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.recordedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private enum MeetingSidebarActivity {
    case preparing
    case recording
    case paused
    case finishing

    var label: String {
        switch self {
        case .preparing: "STARTING"
        case .recording: "RECORDING"
        case .paused: "PAUSED"
        case .finishing: "FINISHING"
        }
    }

    var color: Color {
        switch self {
        case .preparing, .finishing: .secondary
        case .recording: .red
        case .paused: .orange
        }
    }
}

private struct MeetingSidebarRow: View {
    let meeting: MeetingRecord
    var activity: MeetingSidebarActivity? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            sidebarIcon("person.2.fill", color: .blue)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meeting.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if let activity {
                        Text(activity.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(activity.color)
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preview: String {
        let value = meeting.generatedNotes?.overview ?? meeting.rawNotes
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No notes yet"
            : value
    }
}

private func sidebarIcon(_ systemName: String, color: Color) -> some View {
    Image(systemName: systemName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .frame(width: 24, height: 24)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
}

private struct LiveMeetingWorkspace: View {
    @ObservedObject var session: MeetingSessionController
    let onOpenSettings: () -> Void
    @State private var selectedEvidenceID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if showsMeetingDocument {
                MeetingDocumentView(
                    meeting: session.meeting,
                    notes: Binding(
                        get: { session.meeting.rawNotes },
                        set: session.updateRawNotes
                    ),
                    selectedEvidenceID: $selectedEvidenceID,
                    isGenerating: isGenerating,
                    generationMessage: generationMessage,
                    generationError: generationError
                )

                if !isGenerating {
                    Divider()
                    MeetingAskPanel(
                        meeting: session.meeting,
                        onOpenEvidence: { selectedEvidenceID = $0 },
                        onSummaryGenerated: session.saveGeneratedNotes,
                        onSelectOutput: session.selectTemplate,
                        onOpenSettings: onOpenSettings
                    )
                }
            } else {
                captureWorkspace
            }
        }
        .onChange(of: session.meeting.id) { _, _ in
            selectedEvidenceID = nil
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

                if session.phase.isCapturing {
                    Label(
                        session.isPaused ? "Paused" : "Recording",
                        systemImage: session.isPaused ? "pause.circle.fill" : "record.circle.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(session.isPaused ? .orange : .red)
                }

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
                } else if session.meeting.endedAt == nil {
                    Button("Start") { session.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }

            if !showsMeetingDocument {
                HStack(spacing: 10) {
                    Text("Notes format")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Notes format", selection: Binding(
                        get: { MeetingTemplateCatalog.template(id: session.meeting.templateID).id },
                        set: session.selectTemplate
                    )) {
                        ForEach(MeetingTemplateCatalog.builtIns) { template in
                            Label(template.name, systemImage: template.systemImage).tag(template.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .help("Choose the notes this meeting will produce")

                    Spacer()
                }
            }

            HStack {
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
        case .recording, .paused:
            EmptyView()
        case .complete:
            Label("Transcript and meeting notes saved locally", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            if generationError == nil {
                HStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if message.contains("Screen & System Audio") {
                        Button("Open Settings") {
                            openScreenCaptureSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your notes")
                .font(.headline)
            ZStack(alignment: .topLeading) {
                if session.meeting.rawNotes.isEmpty {
                    Text("Add context while you talk…")
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
                .accessibilityLabel("Your meeting notes")
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
                        ForEach(displayedTranscript) { segment in
                            TranscriptSegmentRow(segment: segment)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(session.phase.isCapturing
                        ? "Finalized transcript appears here"
                        : "Transcript appears here")
                        .font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    private var hasTranscript: Bool {
        !session.meeting.transcript.isEmpty
    }

    private var displayedTranscript: [MeetingTranscriptSegment] {
        MeetingTranscriptReconciler.newestFirst(session.meeting.transcript)
    }

    private var isBusy: Bool {
        if case .preparing = session.phase { return true }
        if case .finalizing = session.phase { return true }
        return false
    }

    private var showsMeetingDocument: Bool {
        session.meeting.endedAt != nil && !session.phase.isCapturing
    }

    private var isGenerating: Bool {
        if case .finalizing = session.phase { return session.meeting.endedAt != nil }
        return false
    }

    private var generationMessage: String? {
        guard case let .finalizing(message) = session.phase, session.meeting.endedAt != nil else { return nil }
        return message
    }

    private var generationError: String? {
        guard case let .failed(message) = session.phase, session.meeting.endedAt != nil else { return nil }
        let prefix = "Transcript saved, but notes could not be generated: "
        guard message.hasPrefix(prefix) else { return nil }
        return String(message.dropFirst(prefix.count))
    }

    private var duration: String {
        let seconds = Int(session.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func openScreenCaptureSettings() {
        MeetingSystemAudioCapture.requestAuthorizationIfNeeded()
        if !MeetingSystemAudioCapture.isAuthorized {
            MeetingSystemAudioCapture.openPrivacySettings()
        }
    }
}

private struct SavedMeetingView: View {
    @ObservedObject private var store = MeetingStore.shared
    @State private var meeting: MeetingRecord
    @State private var selectedEvidenceID: UUID? = nil
    @State private var isEditing = false
    @State private var didCopy = false
    let onDelete: (MeetingRecord) -> Void
    let onOpenSettings: () -> Void

    init(
        initialMeeting: MeetingRecord,
        onDelete: @escaping (MeetingRecord) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        _meeting = State(initialValue: initialMeeting)
        self.onDelete = onDelete
        self.onOpenSettings = onOpenSettings
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
                Button("Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    copyMarkdown()
                }
                .help(didCopy ? "Copied" : "Copy meeting")
                .accessibilityLabel(didCopy ? "Meeting copied" : "Copy meeting")

                Menu {
                    Button("Edit Meeting", systemImage: "pencil") {
                        isEditing = true
                    }
                    Button("Reveal in Finder", systemImage: "folder") {
                        reveal()
                    }
                    Divider()
                    Button("Delete Meeting", systemImage: "trash", role: .destructive) {
                        onDelete(meeting)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("More meeting actions")
                .accessibilityLabel("More meeting actions")
            }
            .padding(16)

            Divider()

            MeetingDocumentView(
                meeting: meeting,
                selectedEvidenceID: $selectedEvidenceID
            )

            Divider()

            MeetingAskPanel(
                meeting: meeting,
                onOpenEvidence: { segmentID in
                    selectedEvidenceID = segmentID
                },
                onSummaryGenerated: saveGeneratedSummary,
                onSelectOutput: selectOutput,
                onOpenSettings: onOpenSettings
            )
        }
        .sheet(isPresented: $isEditing) {
            SavedMeetingEditor(meeting: $meeting) {
                if store.saveReportingError(meeting) {
                    isEditing = false
                }
            }
        }
    }

    private func saveGeneratedSummary(_ notes: MeetingGeneratedNotes) {
        meeting.generatedNotes = notes
        if meeting.needsGeneratedTitle, let suggestedTitle = notes.suggestedTitle {
            meeting.title = suggestedTitle
        }
        store.saveReportingError(meeting)
    }

    private func selectOutput(_ id: String) {
        meeting.templateID = id
        if let notes = meeting.generatedNotes {
            meeting.generatedNotes = MeetingGeneratedNotesGrounder.grounded(notes, in: meeting)
        }
        store.saveReportingError(meeting)
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
        guard let url = store.exportURLReportingError(for: meeting) else { return }
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
            Text("Edit meeting").font(.title2.weight(.semibold))
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

            Text("Your notes").font(.headline)
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

private struct MeetingDocumentView: View {
    let meeting: MeetingRecord
    var notes: Binding<String>?
    @Binding var selectedEvidenceID: UUID?
    let isGenerating: Bool
    let generationMessage: String?
    let generationError: String?
    @State private var isTranscriptExpanded: Bool

    init(
        meeting: MeetingRecord,
        notes: Binding<String>? = nil,
        selectedEvidenceID: Binding<UUID?>,
        isGenerating: Bool = false,
        generationMessage: String? = nil,
        generationError: String? = nil
    ) {
        self.meeting = meeting
        self.notes = notes
        _selectedEvidenceID = selectedEvidenceID
        self.isGenerating = isGenerating
        self.generationMessage = generationMessage
        self.generationError = generationError
        _isTranscriptExpanded = State(initialValue: selectedEvidenceID.wrappedValue != nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GeneratedNotesView(
                        meeting: meeting,
                        isGenerating: isGenerating,
                        progressMessage: generationMessage,
                        errorMessage: generationError,
                        onEvidence: { evidenceID in
                            isTranscriptExpanded = true
                            selectedEvidenceID = evidenceID
                        }
                    )

                    Divider()

                    personalNotes

                    Divider()

                    transcript
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear {
                guard selectedEvidenceID != nil else { return }
                isTranscriptExpanded = true
                scrollToEvidence(using: proxy)
            }
            .onChange(of: selectedEvidenceID) { _, evidenceID in
                guard evidenceID != nil else { return }
                isTranscriptExpanded = true
                scrollToEvidence(using: proxy)
            }
        }
    }

    private var personalNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your notes")
                    .font(.headline)
                Spacer()
                Text("Included in generated notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notes {
                ZStack(alignment: .topLeading) {
                    if notes.wrappedValue.isEmpty {
                        Text("Add context or details you want reflected in the output…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: notes)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 92, maxHeight: 150)
                        .accessibilityLabel("Your meeting notes")
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
            } else if meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No personal notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(meeting.rawNotes)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private var transcript: some View {
        DisclosureGroup(isExpanded: $isTranscriptExpanded) {
            if meeting.transcript.isEmpty {
                Text("No transcript was captured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(MeetingTranscriptReconciler.newestFirst(meeting.transcript)) { segment in
                        TranscriptSegmentRow(
                            segment: segment,
                            isHighlighted: selectedEvidenceID == segment.id
                        )
                        .id(segment.id)
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Text(meeting.transcript.count == 1 ? "1 segment" : "\(meeting.transcript.count) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    private func scrollToEvidence(using proxy: ScrollViewProxy) {
        guard let selectedEvidenceID else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation { proxy.scrollTo(selectedEvidenceID, anchor: .center) }
        }
    }
}

private struct GeneratedNotesView: View {
    let meeting: MeetingRecord
    var isGenerating = false
    var progressMessage: String?
    var errorMessage: String?
    var onEvidence: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generated notes")
                        .font(.headline)
                    Text(MeetingTemplateCatalog.template(id: meeting.templateID).name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressMessage ?? "Generating meeting notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
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
            } else if !isGenerating {
                VStack(spacing: 8) {
                    Image(systemName: meeting.transcript.isEmpty ? "sparkles" : "sparkles.rectangle.stack")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(meeting.transcript.isEmpty ? "Notes appear after the meeting" : "Ready to generate")
                        .font(.callout.weight(.medium))
                    Text(meeting.transcript.isEmpty
                        ? "Yaprflow uses the transcript and your notes to create structured meeting notes."
                        : "Choose an output below to generate notes, a follow-up, or another useful result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptSegmentRow: View {
    let segment: MeetingTranscriptSegment
    var isHighlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.displaySpeaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .me ? .blue : .purple)
                Text(segment.text)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var timestamp: String {
        MeetingTranscriptTimestamp.string(for: segment.startTime)
    }
}

@MainActor
enum MeetingNotesWindowController {
    private static let window = FeatureWindowController(
        title: "Meeting Notes",
        contentSize: NSSize(width: 980, height: 680),
        minimumSize: NSSize(width: 820, height: 580)
    ) {
        MeetingNotesView()
    }

    static func show(selection: MeetingWorkspaceSelection? = nil) {
        if let selection {
            MeetingNotesNavigation.shared.selection = selection
        }
        window.show()
    }

    static var isVisibleForSmokeTest: Bool { window.isVisibleForSmokeTest }
    static var isKeyForSmokeTest: Bool { window.isKeyForSmokeTest }
    static var selectionForSmokeTest: MeetingWorkspaceSelection { MeetingNotesNavigation.shared.selection }
}
