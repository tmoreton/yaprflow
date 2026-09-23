import Combine
import Foundation

extension Notification.Name {
    static let yaprflowMeetingsChanged = Notification.Name("yaprflow.meetings.changed")
}

@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var errorMessage: String?

    private let fileManager: FileManager
    private let rootOverride: URL?

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride ?? Self.audioSmokeTestRoot()
        refresh()
    }

    private static func audioSmokeTestRoot() -> URL? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test-meeting-audio") else {
            return nil
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "yaprflow-meeting-audio-smoke-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        #else
        return nil
        #endif
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

    func meeting(id: UUID) -> MeetingRecord? {
        meetings.first { $0.id == id }
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
            NotificationCenter.default.post(name: .yaprflowMeetingsChanged, object: saved.meeting.id)
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

    /// Removes both durable representations of a meeting. Production files are
    /// moved to the Trash so an accidental deletion remains recoverable.
    @discardableResult
    func delete(_ meeting: MeetingRecord) -> Bool {
        do {
            let urls = try diskStore().fileURLs(for: meeting.id)

            // Delete the indexable JSON last. If moving the Markdown export
            // fails, the meeting remains visible and can be retried safely.
            try discardFileIfPresent(at: urls.markdown)
            try discardFileIfPresent(at: urls.json)
            meetings.removeAll { $0.id == meeting.id }
            errorMessage = nil
            NotificationCenter.default.post(name: .yaprflowMeetingsChanged, object: meeting.id)
            return true
        } catch {
            let message = error.localizedDescription
            refresh()
            errorMessage = message
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func meetingsDirectory() throws -> URL {
        let root: URL
        if let rootOverride {
            root = rootOverride
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            root = applicationSupport
                .appendingPathComponent("Yaprflow", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
            .appendingPathComponent("yaprflow-meeting-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = MeetingStore(rootOverride: directory)
            let segment = MeetingTranscriptSegment(
                speaker: .me,
                startTime: 0,
                endTime: 2,
                text: "Persistence smoke test"
            )
            let meeting = MeetingRecord(title: "Smoke test", transcript: [segment])
            let markdownURL = try store.save(meeting)
            store.refresh()
            let jsonURL = directory.appendingPathComponent(meeting.id.uuidString).appendingPathExtension("json")
            let persisted = store.meeting(id: meeting.id)?.transcript.first == segment
                && FileManager.default.fileExists(atPath: jsonURL.path)
                && FileManager.default.fileExists(atPath: markdownURL.path)
            guard persisted, store.delete(meeting) else { return false }
            return store.meeting(id: meeting.id) == nil
                && !FileManager.default.fileExists(atPath: jsonURL.path)
                && !FileManager.default.fileExists(atPath: markdownURL.path)
        } catch {
            return false
        }
    }

    private func discardFileIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if rootOverride != nil {
            try fileManager.removeItem(at: url)
        } else {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }
}
