import Combine
import Foundation

enum MobileMeetingStoreError: LocalizedError {
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .emptyCapture:
            return "No speech or notes were captured for this meeting."
        }
    }
}

/// Local, durable storage for microphone-only meetings captured on iPhone and
/// iPad. It deliberately writes the same JSON model and Markdown representation
/// as macOS so the records are ready for a future private sync layer without a
/// migration or a second mobile-only schema.
@MainActor
final class MobileMeetingStore: ObservableObject {
    static let shared = MobileMeetingStore()

    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var lastSavedMeetingID: UUID?
    @Published private(set) var errorMessage: String?
    @Published var draftTitle = ""
    @Published var draftNotes = ""
    @Published var draftTemplateID = MeetingTemplateCatalog.generalID

    private let fileManager: FileManager
    private let rootOverride: URL?

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        refresh()
    }

    var hasDraftContent: Bool {
        !draftNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refresh() {
        do {
            let result = try diskStore().load()
            meetings = result.meetings
            errorMessage = recoveryMessage(for: result.issues)
        } catch {
            meetings = []
            errorMessage = "The meeting library could not be loaded: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveCapture(
        transcript: String,
        startedAt: Date,
        endedAt: Date,
        duration: TimeInterval
    ) throws -> MeetingRecord {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNotes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty || !cleanedNotes.isEmpty else {
            throw MobileMeetingStoreError.emptyCapture
        }

        let segments: [MeetingTranscriptSegment]
        if cleanedTranscript.isEmpty {
            segments = []
        } else {
            segments = [
                MeetingTranscriptSegment(
                    speaker: .unknown,
                    startTime: 0,
                    endTime: max(0, duration),
                    text: cleanedTranscript
                ),
            ]
        }

        let meeting = MeetingRecord(
            title: cleanedTitle.isEmpty ? Self.defaultTitle(for: startedAt) : cleanedTitle,
            startedAt: startedAt,
            endedAt: endedAt,
            rawNotes: cleanedNotes,
            transcript: segments,
            templateID: draftTemplateID
        )
        try save(meeting)
        lastSavedMeetingID = meeting.id
        return meeting
    }

    @discardableResult
    func save(_ meeting: MeetingRecord) throws -> URL {
        do {
            let saved = try diskStore().save(meeting)
            if let index = meetings.firstIndex(where: { $0.id == saved.meeting.id }) {
                meetings[index] = saved.meeting
            } else {
                meetings.append(saved.meeting)
            }
            meetings.sort { $0.startedAt > $1.startedAt }
            errorMessage = nil
            return saved.exportURL
        } catch {
            errorMessage = "The meeting could not be saved: \(error.localizedDescription)"
            throw error
        }
    }

    @discardableResult
    func saveReportingError(_ meeting: MeetingRecord) -> Bool {
        do {
            _ = try save(meeting)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(_ meeting: MeetingRecord) -> Bool {
        do {
            let urls = try diskStore().fileURLs(for: meeting.id)
            for url in [urls.json, urls.markdown] {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
            meetings.removeAll { $0.id == meeting.id }
            if lastSavedMeetingID == meeting.id { lastSavedMeetingID = nil }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func exportURL(for meeting: MeetingRecord) throws -> URL {
        do {
            let url = try diskStore().exportURL(for: meeting)
            errorMessage = nil
            return url
        } catch {
            errorMessage = "The meeting export could not be created: \(error.localizedDescription)"
            throw error
        }
    }

    func exportURLReportingError(for meeting: MeetingRecord) -> URL? {
        do {
            return try exportURL(for: meeting)
        } catch {
            return nil
        }
    }

    func resetDraft() {
        draftTitle = ""
        draftNotes = ""
        draftTemplateID = MeetingTemplateCatalog.generalID
    }

    func clearError() {
        errorMessage = nil
    }

    /// Preserve the just-saved meeting on screen until the user deliberately
    /// starts another capture, then clear the old metadata for the new record.
    func prepareNewCapture() {
        guard lastSavedMeetingID != nil else { return }
        resetDraft()
        lastSavedMeetingID = nil
    }

    func meetingsDirectory() throws -> URL {
        let directory: URL
        if let rootOverride {
            directory = rootOverride
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = applicationSupport
                .appendingPathComponent("Yaprflow", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func diskStore() throws -> MeetingRecordDiskStore {
        MeetingRecordDiskStore(
            directory: try meetingsDirectory(),
            fileManager: fileManager
        )
    }

    private func recoveryMessage(for issues: [MeetingStorageIssue]) -> String? {
        guard !issues.isEmpty else { return nil }
        let noun = issues.count == 1 ? "file was" : "files were"
        return "\(issues.count) unreadable meeting \(noun) moved to the \(MeetingRecordDiskStore.recoveryDirectoryName) folder. Your other meetings are still available."
    }

    static func runPersistenceSmokeTest() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaprflow-ios-meeting-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = MobileMeetingStore(rootOverride: directory)
            store.draftTitle = "In-person planning"
            store.draftNotes = "Confirm the launch owner."
            let meeting = try store.saveCapture(
                transcript: "We agreed to ship on Friday.",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_030),
                duration: 30
            )
            store.refresh()
            let markdownURL = try store.exportURL(for: meeting)
            let markdown = try String(
                contentsOf: markdownURL,
                encoding: .utf8
            )
            let persisted = store.meetings.first == meeting
                && markdown.contains("We agreed to ship on Friday.")
                && markdown.contains("Confirm the launch owner.")
            guard persisted, store.delete(meeting) else { return false }
            let jsonURL = directory
                .appendingPathComponent(meeting.id.uuidString)
                .appendingPathExtension("json")
            return store.meetings.isEmpty
                && !FileManager.default.fileExists(atPath: jsonURL.path)
                && !FileManager.default.fileExists(atPath: markdownURL.path)
        } catch {
            return false
        }
    }

    private static func defaultTitle(for date: Date) -> String {
        "In-person meeting — \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
