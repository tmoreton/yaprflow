#if os(iOS)
import Combine
import MessageUI
import SwiftUI
import UIKit

private enum MobileLibrarySection: String, CaseIterable, Identifiable {
    case dictations = "Dictations"
    case meetings = "Meetings"

    var id: Self { self }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var engine = TranscriptionEngine.shared
    @StateObject private var history = HistoryStore.shared
    @StateObject private var meetings = MobileMeetingStore.shared
    @AppStorage("yaprflow.captureMode") private var selectedModeRaw = MobileCaptureMode.quick.rawValue
    @State private var showLibrary = false
    @State private var initialLibrarySection = MobileLibrarySection.dictations
    @State private var showAcknowledgements = false
    @State private var showFeedback = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                    .padding(.horizontal, 20)

                modeSelector
                    .padding(.top, 12)
                    .padding(.horizontal, 24)

                switch displayedMode {
                case .quick:
                    quickContent
                case .meeting:
                    meetingContent
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            captureControl
        }
        .preferredColorScheme(.dark)
        .onAppear {
            engine.preload()
            configureDebugSmokeRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                engine.applicationDidEnterBackground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            engine.applicationDidReceiveMemoryWarning()
        }
        .sheet(isPresented: $showLibrary) {
            LibrarySheet(
                history: history,
                store: meetings,
                initialSection: initialLibrarySection
            )
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet()
        }
        .onChange(of: selectedModeRaw) { _, _ in
            engine.resetPresentation()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Yaprflow")
                .font(.system(size: 21, weight: .semibold, design: .rounded))

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                initialLibrarySection = selectedMode == .quick ? .dictations : .meetings
                showLibrary = true
            } label: {
                Label("Library", systemImage: "books.vertical")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    showFeedback = true
                } label: {
                    Label("Send Feedback", systemImage: "bubble.left")
                }
                Button {
                    showAcknowledgements = true
                } label: {
                    Label("About Yaprflow", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .accessibilityLabel("More options")
        }
    }

    private var modeSelector: some View {
        VStack(spacing: 8) {
            Picker("Capture mode", selection: modeBinding) {
                ForEach(MobileCaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isBusy)
            .accessibilityHint("Choose clipboard dictation or an in-person meeting")

            Label(modeSubtitle, systemImage: selectedMode == .quick ? "doc.on.clipboard" : "lock.fill")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: 390)
    }

    private var quickContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Waveform(levels: engine.levels, isActive: engine.isRecording)
                .frame(height: 96)
                .padding(.horizontal, 24)

            Spacer(minLength: 24)

            if !engine.liveTranscript.isEmpty {
                transcript
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }

            Spacer(minLength: 12)
        }
    }

    private var meetingContent: some View {
        ScrollView {
            Group {
                if horizontalSizeClass == .regular {
                    HStack(alignment: .top, spacing: 24) {
                        meetingSetup
                            .frame(maxWidth: .infinity, alignment: .top)
                        meetingLivePanel
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    VStack(spacing: 18) {
                        meetingSetup
                        meetingLivePanel
                    }
                }
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 56 : 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var meetingSetup: some View {
        VStack(spacing: 12) {
            TextField("Meeting title (optional)", text: $meetings.draftTitle)
                .textInputAutocapitalization(.sentences)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .padding(12)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Meeting title")

            HStack {
                Label("Notes format", systemImage: "rectangle.3.group")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(MeetingTemplateCatalog.builtIns) { template in
                        Button {
                            meetings.draftTemplateID = template.id
                        } label: {
                            Label(
                                template.name,
                                systemImage: template.id == selectedMeetingTemplate.id
                                    ? "checkmark"
                                    : template.systemImage
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedMeetingTemplate.name)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 10, height: 13)
                    }
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .tint(.white)
                .accessibilityLabel("Notes format, \(selectedMeetingTemplate.name)")
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .padding(.horizontal, 12)

            ZStack(alignment: .topLeading) {
                if meetings.draftNotes.isEmpty {
                    Text("Add notes while you talk…")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $meetings.draftNotes)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: horizontalSizeClass == .regular ? 180 : 96)
                    .accessibilityLabel("Your meeting notes")
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var meetingLivePanel: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Live transcript")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                if engine.isRecording, let startedAt = engine.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.durationString(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Meeting duration")
                    }
                }
            }

            Waveform(levels: engine.levels, isActive: engine.isRecording)
                .frame(height: horizontalSizeClass == .regular ? 72 : 56)

            Group {
                if engine.liveTranscript.isEmpty {
                    ContentUnavailableView(
                        "Transcript appears here",
                        systemImage: "waveform",
                        description: Text("Finalized speech appears after each pause.")
                    )
                } else {
                    Text(engine.liveTranscript)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Live meeting transcript")
                }
            }
            .frame(maxWidth: .infinity, minHeight: horizontalSizeClass == .regular ? 180 : 92, alignment: .topLeading)
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var transcript: some View {
        Text(engine.liveTranscript)
            .font(.system(size: 17, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .animation(.easeInOut(duration: 0.15), value: engine.liveTranscript)
    }

    private var captureControl: some View {
        VStack(spacing: 8) {
            if let captureFeedback {
                Text(captureFeedback)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(captureFeedbackColor)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if selectedMode == .meeting, !engine.isBusy {
                    meetings.prepareNewCapture()
                }
                engine.toggle(mode: selectedMode)
            } label: {
                HStack(spacing: 10) {
                    if captureControlDisabled {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Image(systemName: captureButtonSymbol)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(captureButtonTitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(showsStopControl ? Color.white : Color.black)
                .frame(maxWidth: 360)
                .frame(height: 54)
                .background(showsStopControl ? Color.red : Color.white, in: Capsule())
                .shadow(
                    color: showsStopControl ? Color.red.opacity(0.3) : .clear,
                    radius: showsStopControl ? 16 : 0
                )
                .animation(.easeInOut(duration: 0.18), value: showsStopControl)
            }
            .buttonStyle(.plain)
            .disabled(captureControlDisabled)
            .accessibilityLabel(captureButtonTitle)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.96))
    }

    private var captureButtonTitle: String {
        if engine.isRecordingPending { return "Cancel" }
        if engine.isRecording {
            return selectedMode == .quick ? "Stop dictation" : "Stop meeting"
        }
        if captureControlDisabled { return "Finishing…" }
        return selectedMode == .quick ? "Start dictation" : "Start meeting"
    }

    private var captureButtonSymbol: String {
        if engine.isRecordingPending { return "xmark" }
        return engine.isRecording ? "stop.fill" : "mic.fill"
    }

    private var captureControlDisabled: Bool {
        engine.isBusy && !engine.isRecording && !engine.isRecordingPending
    }

    private var captureFeedback: String? {
        switch engine.status {
        case .idle, .listening: nil
        case .preparing(let message): message
        case .finishing: "Finishing…"
        case .copied: "Copied to clipboard"
        case .saved: "Meeting saved locally"
        case .error(let message): message
        }
    }

    private var captureFeedbackColor: Color {
        if case .error = engine.status { return .orange }
        return .secondary
    }

    private var showsStopControl: Bool {
        engine.isRecording || engine.isRecordingPending
    }

    private var selectedMode: MobileCaptureMode {
        MobileCaptureMode(rawValue: selectedModeRaw) ?? .quick
    }

    private var displayedMode: MobileCaptureMode {
        engine.activeMode ?? selectedMode
    }

    private var modeBinding: Binding<MobileCaptureMode> {
        Binding(
            get: { selectedMode },
            set: { selectedModeRaw = $0.rawValue }
        )
    }

    private var modeSubtitle: String {
        switch selectedMode {
        case .quick: "Copies finished text to the clipboard"
        case .meeting: "Microphone only • Audio isn’t saved • Stored locally"
        }
    }

    private var selectedMeetingTemplate: MeetingTemplate {
        MeetingTemplateCatalog.template(id: meetings.draftTemplateID)
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func configureDebugSmokeRoute() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--smoke-test-dictation") {
            selectedModeRaw = MobileCaptureMode.quick.rawValue
        } else if arguments.contains("--smoke-test-meeting") {
            selectedModeRaw = MobileCaptureMode.meeting.rawValue
            meetings.draftTitle = "Production readiness"
            meetings.draftNotes = "Typed notes stay local and remain available with the transcript."
        }
        Task { @MainActor in
            await Task.yield()
            if arguments.contains("--smoke-test-feedback") {
                showFeedback = true
            } else if arguments.contains("--smoke-test-meeting-library") {
                selectedModeRaw = MobileCaptureMode.meeting.rawValue
                initialLibrarySection = .meetings
                showLibrary = true
            } else if arguments.contains("--smoke-test-history") {
                initialLibrarySection = .dictations
                showLibrary = true
            }
        }
        #endif
    }
}

// MARK: - Library

private struct LibrarySheet: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var store: MobileMeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: MobileLibrarySection

    init(
        history: HistoryStore,
        store: MobileMeetingStore,
        initialSection: MobileLibrarySection
    ) {
        _history = ObservedObject(wrappedValue: history)
        _store = ObservedObject(wrappedValue: store)
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Library section", selection: $selectedSection) {
                    ForEach(MobileLibrarySection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch selectedSection {
                case .dictations:
                    HistorySheet(history: history)
                case .meetings:
                    MeetingLibraryContent(store: store)
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MeetingRecord.self) { meeting in
                MobileMeetingDetailView(meeting: meeting, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.black)
    }
}

// MARK: - Meeting library

private struct MeetingLibraryContent: View {
    @ObservedObject var store: MobileMeetingStore
    @State private var meetingPendingDeletion: MeetingRecord?

    var body: some View {
        Group {
            if store.meetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "person.2.wave.2",
                    description: Text("Use Meeting mode to capture an in-person conversation.")
                )
            } else {
                List {
                    ForEach(store.meetings) { meeting in
                        NavigationLink(value: meeting) {
                            MeetingLibraryRow(meeting: meeting)
                        }
                    }
                    .onDelete { offsets in
                        guard let offset = offsets.first,
                              store.meetings.indices.contains(offset) else { return }
                        meetingPendingDeletion = store.meetings[offset]
                    }
                }
            }
        }
        .onAppear { store.refresh() }
        .alert(
            "Couldn’t update meetings",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { store.clearError() }
                }
            )
        ) {
            Button("OK") { store.clearError() }
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { if !$0 { meetingPendingDeletion = nil } }
            )
        ) {
            Button("Delete Meeting", role: .destructive) {
                if let meetingPendingDeletion {
                    store.delete(meetingPendingDeletion)
                    self.meetingPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                meetingPendingDeletion = nil
            }
        } message: {
            Text("This removes the transcript and notes from this device.")
        }
    }
}

private struct MeetingLibraryRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if !meeting.transcript.isEmpty {
                    Label("Transcript", systemImage: "text.quote")
                }
                if !meeting.rawNotes.isEmpty {
                    Label("Notes", systemImage: "note.text")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MobileMeetingDetailView: View {
    let meeting: MeetingRecord
    @ObservedObject var store: MobileMeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var copied = false
    @State private var confirmsDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Notes format")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label(
                            MeetingTemplateCatalog.template(id: meeting.templateID).name,
                            systemImage: "rectangle.3.group"
                        )
                    }
                    .font(.callout.weight(.medium))
                }

                if !meeting.rawNotes.isEmpty {
                    meetingSection(title: "Your notes", text: meeting.rawNotes)
                }

                meetingSection(
                    title: "Transcript",
                    text: meeting.plainTranscript.isEmpty
                        ? "No speech was detected."
                        : meeting.plainTranscript
                )

                Text("Captured from this device’s microphone. Audio was not saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = MeetingMarkdownRenderer.render(meeting)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Copied meeting" : "Copy meeting")

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share meeting")
                }

                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete meeting")
            }
        }
        .onAppear {
            exportURL = store.exportURLReportingError(for: meeting)
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $confirmsDeletion
        ) {
            Button("Delete Meeting", role: .destructive) {
                if store.delete(meeting) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the transcript and notes from this device.")
        }
    }

    private func meetingSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Feedback sheet

private struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var kind: FeedbackKind = .problem
    @State private var subject = ""
    @State private var message = ""
    @State private var showMailComposer = false
    @State private var mailUnavailable = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(FeedbackKind.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    TextField("Short summary", text: $subject)
                        .accessibilityLabel("Feedback summary")
                    TextEditor(text: $message)
                        .frame(minHeight: 150)
                        .accessibilityLabel("Feedback details")
                } header: {
                    Text("What would you like us to know?")
                } footer: {
                    Text("Describe the issue or idea. Please leave out private transcripts and recordings.")
                }

                Section {
                    Text("A Mail draft will open for you to review and send. The draft includes your message, Yaprflow version, and operating-system version.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Continue in Mail") { composeEmail() }
                        .disabled(!canCompose)
                }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMailComposer) {
            FeedbackMailComposer(subject: emailSubject, body: emailBody) {
                showMailComposer = false
            }
        }
        .alert("Email app unavailable", isPresented: $mailUnavailable) {
            Button("Copy message") { UIPasteboard.general.string = emailBody }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy your message and email it to tim@yaprflow.com when an email app is available.")
        }
    }

    private var canCompose: Bool {
        draft.canCompose
    }

    private var emailSubject: String {
        draft.emailSubject
    }

    private var emailBody: String {
        draft.emailBody
    }

    private var draft: FeedbackDraft {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return FeedbackDraft(
            kind: kind,
            summary: subject,
            details: message,
            version: version,
            build: build,
            operatingSystem: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
    }

    private func composeEmail() {
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
            return
        }

        guard let url = draft.mailtoURL else {
            mailUnavailable = true
            return
        }
        openURL(url) { accepted in
            if !accepted { mailUnavailable = true }
        }
    }
}

private struct FeedbackMailComposer: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([FeedbackDraft.recipient])
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}

// MARK: - Acknowledgements sheet

private struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let contents: String = {
        guard
            let url = Bundle.main.url(
                forResource: "Acknowledgements",
                withExtension: "txt"
            ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Acknowledgements are unavailable in this build."
        }
        return text
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Link(destination: URL(string: "https://yaprflow.com/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                            .font(.headline)
                    }

                    Divider()

                    Text(Self.contents)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - History sheet

private enum HistoryDeletionTarget {
    case item(String)
    case all
}

private struct HistorySheet: View {
    @ObservedObject var history: HistoryStore
    @State private var copiedItem: String?
    @State private var deletionTarget: HistoryDeletionTarget?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent dictations")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                        .textCase(.uppercase)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        deletionTarget = .all
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .disabled(history.items.isEmpty)
                    .accessibilityLabel("Clear transcript history")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

                if history.items.isEmpty {
                    ScrollView {
                        ContentUnavailableView(
                            "No recent dictations",
                            systemImage: "mic",
                            description: Text("Finished dictations will appear here after they’re copied.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 36)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(history.items, id: \.self) { item in
                                HistoryRow(
                                    text: item,
                                    isCopied: copiedItem == item,
                                    onCopy: { copy(item) },
                                    onDelete: { deletionTarget = .item(item) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deletionTarget {
                switch deletionTarget {
                case let .item(item):
                    Button("Delete Dictation", role: .destructive) {
                        history.delete(item)
                        self.deletionTarget = nil
                    }
                case .all:
                    Button("Clear History", role: .destructive) {
                        history.clear()
                        self.deletionTarget = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletionTarget = nil
            }
        } message: {
            Text(deletionMessage)
        }
    }

    private var deletionTitle: String {
        switch deletionTarget {
        case .item: "Delete this dictation?"
        case .all: "Clear recent transcripts?"
        case nil: "Delete dictation?"
        }
    }

    private var deletionMessage: String {
        switch deletionTarget {
        case .item: "This removes the saved transcript text from this device."
        case .all: "This removes all saved transcript text from this device."
        case nil: "This removes saved transcript text from this device."
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedItem = text
        Task {
            try? await Task.sleep(for: .seconds(1.0))
            await MainActor.run {
                if copiedItem == text { copiedItem = nil }
            }
        }
    }
}

// MARK: - Waveform

private struct Waveform: View {
    let levels: [Float]
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let barSpacing: CGFloat = 2
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(count))
            let mid = geo.size.height / 2
            let maxHeight = geo.size.height * 0.95

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<count, id: \.self) { i in
                    let level = CGFloat(levels[i])
                    // Floor of ~1.5px so idle still shows a faint line.
                    let h = max(1.5, level * maxHeight)
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(barOpacity(level: level)))
                        .frame(width: barWidth, height: h)
                        .animation(.easeOut(duration: 0.08), value: levels[i])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .position(x: geo.size.width / 2, y: mid)
        }
    }

    private func barOpacity(level: CGFloat) -> Double {
        if isActive {
            return 0.35 + min(0.55, Double(level) * 0.8)
        } else {
            return 0.18 + min(0.4, Double(level) * 0.6)
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let text: String
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onCopy) {
                HStack(alignment: .top, spacing: 10) {
                    Text(text)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isCopied ? Color.green : Color.secondary)
                        .frame(width: 18)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete dictation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
#endif
