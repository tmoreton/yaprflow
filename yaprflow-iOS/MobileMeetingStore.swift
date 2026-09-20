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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        refresh()
    }

    var hasDraftContent: Bool {
        !draftNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refresh() {
        do {
            let directory = try meetingsDirectory()
            meetings = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard url.pathExtension == "json",
                      let data = try? Data(contentsOf: url),
                      let meeting = try? decoder.decode(MeetingRecord.self, from: data)
                else { return nil }
                return meeting
            }.sorted { $0.startedAt > $1.startedAt }
            errorMessage = nil
        } catch {
            meetings = []
            errorMessage = error.localizedDescription
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
        let directory = try meetingsDirectory()
        let jsonURL = directory
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathExtension("json")
        try encoder.encode(meeting).write(to: jsonURL, options: .atomic)

        let markdownURL = directory
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathExtension("md")
        try MeetingMarkdownRenderer.render(meeting).write(
            to: markdownURL,
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
        return markdownURL
    }

    @discardableResult
    func delete(_ meeting: MeetingRecord) -> Bool {
        do {
            let directory = try meetingsDirectory()
            for pathExtension in ["json", "md"] {
                let url = directory
                    .appendingPathComponent(meeting.id.uuidString)
                    .appendingPathExtension(pathExtension)
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
        let url = try meetingsDirectory()
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathExtension("md")
        if !fileManager.fileExists(atPath: url.path) {
            _ = try save(meeting)
        }
        return url
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
