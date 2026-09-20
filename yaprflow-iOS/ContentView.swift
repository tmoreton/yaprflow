#if os(iOS)
import Combine
import MessageUI
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var engine = TranscriptionEngine.shared
    @StateObject private var history = HistoryStore.shared
    @StateObject private var meetings = MobileMeetingStore.shared
    @AppStorage("yaprflow.captureMode") private var selectedModeRaw = MobileCaptureMode.quick.rawValue
    @State private var showHistory = false
    @State private var showMeetingLibrary = false
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
        .preferredColorScheme(.dark)
        .onAppear { engine.preload() }
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
        .sheet(isPresented: $showHistory) {
            HistorySheet(history: history)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
        }
        .sheet(isPresented: $showMeetingLibrary) {
            MeetingLibrarySheet(store: meetings)
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
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showAcknowledgements = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About and acknowledgements")

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showFeedback = true
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send feedback")

            Menu {
                Picker("Speech language", selection: $engine.speechLanguage) {
                    ForEach(SpeechLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .disabled(engine.isBusy)
            .opacity(engine.isBusy ? 0.4 : 1)
            .accessibilityLabel("Speech language, \(engine.speechLanguage.displayName)")

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if selectedMode == .quick {
                    showHistory = true
                } else {
                    showMeetingLibrary = true
                }
            } label: {
                Image(systemName: selectedMode == .quick ? "clock" : "books.vertical")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedMode == .quick ? "Recent transcripts" : "Saved meetings")
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

            Label(modeSubtitle, systemImage: selectedMode == .quick ? "doc.on.clipboard" : "person.2")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
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

            statusText
                .padding(.top, 16)
                .frame(height: 38)

            Spacer(minLength: 12)

            if !engine.liveTranscript.isEmpty {
                transcript
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }

            micButton
                .padding(.bottom, 56)
        }
    }

    private var meetingContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                meetingPrivacyCard

                VStack(spacing: 12) {
                    TextField("Meeting title (optional)", text: $meetings.draftTitle)
                        .textInputAutocapitalization(.sentences)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .padding(12)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Meeting title")

                    HStack {
                        Label("Template", systemImage: "rectangle.3.group")
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        Picker("Meeting template", selection: $meetings.draftTemplateID) {
                            ForEach(MeetingTemplateCatalog.builtIns) { template in
                                Text(template.name).tag(template.id)
                            }
                        }
                        .tint(.white)
                    }
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .padding(.horizontal, 12)

                    ZStack(alignment: .topLeading) {
                        if meetings.draftNotes.isEmpty {
                            Text("Type notes while you talk…")
                                .font(.system(size: 15, design: .rounded))
                                .foregroundStyle(.white.opacity(0.32))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 15)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $meetings.draftNotes)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 96)
                            .accessibilityLabel("My meeting notes")
                    }
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }

                Waveform(levels: engine.levels, isActive: engine.isRecording)
                    .frame(height: 64)

                HStack(spacing: 8) {
                    statusText
                    if engine.isRecording, let startedAt = engine.recordingStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.durationString(context.date.timeIntervalSince(startedAt)))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.9))
                                .accessibilityLabel("Meeting duration")
                        }
                    }
                }
                .frame(minHeight: 22)

                if !engine.liveTranscript.isEmpty {
                    Text(engine.liveTranscript)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Live meeting transcript")
                }

                micButton
                    .padding(.top, 2)
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 56 : 20)
            .padding(.top, 14)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var meetingPrivacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("In-person meeting")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Uses this device’s microphone. Audio is never saved; transcript and notes stay local.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
        )
    }

    private var transcript: some View {
        Text(engine.liveTranscript)
            .font(.system(size: 17, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .animation(.easeInOut(duration: 0.15), value: engine.liveTranscript)
    }

    private var statusText: some View {
        Text(statusLabel)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(statusColor)
            .animation(.easeInOut(duration: 0.2), value: statusLabel)
            .multilineTextAlignment(.center)
    }

    private var statusLabel: String {
        switch engine.status {
        case .idle:
            return selectedMode == .quick ? "Tap to dictate" : "Tap to start meeting"
        case .preparing(let msg): return msg
        case .listening: return selectedMode == .quick ? "Listening" : "Recording"
        case .finishing: return "Finishing"
        case .copied: return "Copied"
        case .saved: return "Meeting saved locally"
        case .error(let msg): return msg
        }
    }

    private var statusColor: Color {
        if case .error = engine.status { return .orange }
        if engine.isRecording { return .red.opacity(0.9) }
        return .white.opacity(0.45)
    }

    private var micButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if selectedMode == .meeting, !engine.isBusy {
                meetings.prepareNewCapture()
            }
            engine.toggle(mode: selectedMode)
        } label: {
            ZStack {
                Circle()
                    .fill(showsStopControl ? Color.red : Color.white)
                    .frame(width: 76, height: 76)
                    .shadow(color: showsStopControl ? Color.red.opacity(0.45) : .clear,
                            radius: showsStopControl ? 22 : 0)

                Image(systemName: showsStopControl ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(showsStopControl ? .white : .black)
            }
            .scaleEffect(showsStopControl ? 1.04 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: showsStopControl)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            showsStopControl
                ? "Stop \(selectedMode == .quick ? "dictation" : "meeting")"
                : "Start \(selectedMode == .quick ? "dictation" : "meeting")"
        )
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
        case .quick: "Voice to text • Copies to clipboard"
        case .meeting: "In-person • Microphone only • Saved locally"
        }
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Meeting library

private struct MeetingLibrarySheet: View {
    @ObservedObject var store: MobileMeetingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                            for offset in offsets {
                                store.delete(store.meetings[offset])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
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
    @State private var exportURL: URL?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                        .foregroundStyle(.secondary)
                    Label(
                        MeetingTemplateCatalog.template(id: meeting.templateID).name,
                        systemImage: "rectangle.3.group"
                    )
                    .font(.callout.weight(.medium))
                }

                if !meeting.rawNotes.isEmpty {
                    meetingSection(title: "My notes", text: meeting.rawNotes)
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
            }
        }
        .onAppear {
            exportURL = try? store.exportURL(for: meeting)
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

private enum FeedbackKind: String, CaseIterable, Identifiable {
    case problem = "Problem"
    case suggestion = "Suggestion"
    case question = "Question"

    var id: Self { self }
}

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
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emailSubject: String {
        "Yaprflow \(kind.rawValue): \(subject.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private var emailBody: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return """
        Type: \(kind.rawValue)
        Summary: \(subject.trimmingCharacters(in: .whitespacesAndNewlines))

        \(message.trimmingCharacters(in: .whitespacesAndNewlines))

        ---
        Yaprflow \(version) (\(build))
        \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        """
    }

    private func composeEmail() {
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
            return
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "tim@yaprflow.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: emailSubject),
            URLQueryItem(name: "body", value: emailBody),
        ]
        guard let url = components.url else {
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
        composer.setToRecipients(["tim@yaprflow.com"])
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

private struct HistorySheet: View {
    @ObservedObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var copiedItem: String?
    @State private var showClearConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(0.6)
                        .textCase(.uppercase)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .disabled(history.items.isEmpty)
                    .accessibilityLabel("Clear transcript history")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history.items, id: \.self) { item in
                            HistoryRow(
                                text: item,
                                isCopied: copiedItem == item,
                                onCopy: { copy(item) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .confirmationDialog(
            "Clear recent transcripts?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved transcript text from this device.")
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

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .top, spacing: 10) {
                Text(text)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCopied ? Color.green : .white.opacity(0.4))
                    .frame(width: 18)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}
#endif
