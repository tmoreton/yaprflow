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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride ?? Self.audioSmokeTestRoot()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
            let directory = try meetingsDirectory()
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            meetings = urls.compactMap { url in
                guard url.pathExtension == "json",
                      let data = try? Data(contentsOf: url),
                      var meeting = try? decoder.decode(MeetingRecord.self, from: data) else {
                    return nil
                }
                meeting.transcript = MeetingTranscriptReconciler.reconcile(meeting.transcript)
                if let notes = meeting.generatedNotes {
                    meeting.generatedNotes = MeetingGeneratedNotesGrounder.grounded(notes, in: meeting)
                }
                return meeting
            }.sorted { $0.startedAt > $1.startedAt }
            errorMessage = nil
        } catch {
            meetings = []
            errorMessage = error.localizedDescription
        }
    }

    func meeting(id: UUID) -> MeetingRecord? {
        meetings.first { $0.id == id }
    }

    @discardableResult
    func save(_ meeting: MeetingRecord) throws -> URL {
        var meeting = meeting
        meeting.transcript = MeetingTranscriptReconciler.reconcile(meeting.transcript)
        if let notes = meeting.generatedNotes {
            meeting.generatedNotes = MeetingGeneratedNotesGrounder.grounded(notes, in: meeting)
        }
        let directory = try meetingsDirectory()
        let jsonURL = directory.appendingPathComponent(meeting.id.uuidString).appendingPathExtension("json")
        let data = try encoder.encode(meeting)
        try data.write(to: jsonURL, options: .atomic)

        let exportURL = directory.appendingPathComponent(meeting.id.uuidString).appendingPathExtension("md")
        try MeetingMarkdownRenderer.render(meeting).write(
            to: exportURL,
            atomically: true,
            encoding: .utf8
        )

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings.sort { $0.startedAt > $1.startedAt }
        errorMessage = nil
        NotificationCenter.default.post(name: .yaprflowMeetingsChanged, object: meeting.id)
        return exportURL
    }

    func exportURL(for meeting: MeetingRecord) throws -> URL {
        let url = try meetingsDirectory()
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathExtension("md")
        if !fileManager.fileExists(atPath: url.path) {
            _ = try save(meeting)
        }
        return url
    }

    /// Removes both durable representations of a meeting. Production files are
    /// moved to the Trash so an accidental deletion remains recoverable.
    @discardableResult
    func delete(_ meeting: MeetingRecord) -> Bool {
        do {
            let directory = try meetingsDirectory()
            let markdownURL = directory
                .appendingPathComponent(meeting.id.uuidString)
                .appendingPathExtension("md")
            let jsonURL = directory
                .appendingPathComponent(meeting.id.uuidString)
                .appendingPathExtension("json")

            // Delete the indexable JSON last. If moving the Markdown export
            // fails, the meeting remains visible and can be retried safely.
            try discardFileIfPresent(at: markdownURL)
            try discardFileIfPresent(at: jsonURL)
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
            root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Yaprflow", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
