import Foundation

public struct MeetingStorageIssue: Equatable, Sendable {
    public let fileName: String
    public let recoveryDirectoryName: String
    public let reason: String

    public init(fileName: String, recoveryDirectoryName: String, reason: String) {
        self.fileName = fileName
        self.recoveryDirectoryName = recoveryDirectoryName
        self.reason = reason
    }
}

public struct MeetingStorageLoadResult: Equatable, Sendable {
    public let meetings: [MeetingRecord]
    public let issues: [MeetingStorageIssue]

    public init(meetings: [MeetingRecord], issues: [MeetingStorageIssue]) {
        self.meetings = meetings
        self.issues = issues
    }
}

/// Owns the on-disk representation shared by the Mac and iOS meeting stores.
/// Platform stores remain responsible for published UI state and deletion policy.
public final class MeetingRecordDiskStore {
    public static let recoveryDirectoryName = "Recovery"

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> MeetingStorageLoadResult {
        try prepareDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var meetings: [MeetingRecord] = []
        var issues: [MeetingStorageIssue] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try decoder.decode(MeetingRecord.self, from: data)
                meetings.append(normalized(decoded))
            } catch {
                issues.append(quarantine(url, because: error))
            }
        }

        return MeetingStorageLoadResult(
            meetings: meetings.sorted { $0.startedAt > $1.startedAt },
            issues: issues
        )
    }

    @discardableResult
    public func save(_ meeting: MeetingRecord) throws -> (meeting: MeetingRecord, exportURL: URL) {
        try prepareDirectory()
        let meeting = normalized(meeting)
        let urls = fileURLs(for: meeting.id)

        // Write the derived Markdown first and the indexable JSON record last.
        // A failed export therefore cannot make a new, incomplete record appear
        // in the library.
        try MeetingMarkdownRenderer.render(meeting).write(
            to: urls.markdown,
            atomically: true,
            encoding: .utf8
        )
        try encoder.encode(meeting).write(to: urls.json, options: .atomic)
        return (meeting, urls.markdown)
    }

    public func exportURL(for meeting: MeetingRecord) throws -> URL {
        try prepareDirectory()
        let url = fileURLs(for: meeting.id).markdown
        if !fileManager.fileExists(atPath: url.path) {
            return try save(meeting).exportURL
        }
        return url
    }

    public func fileURLs(for meetingID: UUID) -> (json: URL, markdown: URL) {
        let base = directory.appendingPathComponent(meetingID.uuidString)
        return (
            base.appendingPathExtension("json"),
            base.appendingPathExtension("md")
        )
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func normalized(_ meeting: MeetingRecord) -> MeetingRecord {
        var meeting = meeting
        meeting.transcript = MeetingTranscriptReconciler.reconcile(meeting.transcript)
        if let notes = meeting.generatedNotes {
            let repaired = MeetingGeneratedNotesParser.repairingEmbeddedPayload(
                in: notes,
                validSegmentIDs: Set(meeting.transcript.map(\.id))
            )
            meeting.generatedNotes = MeetingGeneratedNotesGrounder.grounded(repaired, in: meeting)
        }
        return meeting
    }

    private func quarantine(_ jsonURL: URL, because error: Error) -> MeetingStorageIssue {
        let recoveryDirectory = directory.appendingPathComponent(
            Self.recoveryDirectoryName,
            isDirectory: true
        )
        let suffix = UUID().uuidString.lowercased()
        let baseName = jsonURL.deletingPathExtension().lastPathComponent
        let recoveredJSON = recoveryDirectory
            .appendingPathComponent("\(baseName)-\(suffix)")
            .appendingPathExtension("json")

        do {
            try fileManager.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: jsonURL, to: recoveredJSON)

            let markdownURL = jsonURL.deletingPathExtension().appendingPathExtension("md")
            if fileManager.fileExists(atPath: markdownURL.path) {
                let recoveredMarkdown = recoveredJSON
                    .deletingPathExtension()
                    .appendingPathExtension("md")
                try fileManager.moveItem(at: markdownURL, to: recoveredMarkdown)
            }
        } catch let recoveryError {
            return MeetingStorageIssue(
                fileName: jsonURL.lastPathComponent,
                recoveryDirectoryName: Self.recoveryDirectoryName,
                reason: "\(error.localizedDescription) Recovery also failed: \(recoveryError.localizedDescription)"
            )
        }

        return MeetingStorageIssue(
            fileName: jsonURL.lastPathComponent,
            recoveryDirectoryName: Self.recoveryDirectoryName,
            reason: error.localizedDescription
        )
    }
}
