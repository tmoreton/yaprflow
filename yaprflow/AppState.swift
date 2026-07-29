import Combine
import Foundation
import SwiftUI

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case finishing
    case copied
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private static let lastTranscriptKey = "yaprflow.lastTranscript"
    private static let transcriptsFolderName = "Transcripts"

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey

    /// Most recent finalized transcript. Persisted so it survives restarts and
    /// can be re-copied from the menu bar after the clipboard has been replaced.
    @Published var lastTranscript: String {
        didSet {
            UserDefaults.standard.set(lastTranscript, forKey: Self.lastTranscriptKey)
        }
    }

    private init() {
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
    }

    /// Store the newest transcript for quick re-copy and persist each finalized
    /// transcript as a standalone Markdown file.
    func recordTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? Self.writeTranscriptMarkdown(trimmed)
        lastTranscript = trimmed
    }

    func transcriptsDirectory() throws -> URL {
        try Self.ensureTranscriptsDirectory()
    }

    private static func writeTranscriptMarkdown(_ text: String) throws {
        let directory = try ensureTranscriptsDirectory()
        let date = Date()
        let fileURL = uniqueTranscriptURL(in: directory, date: date)
        let recordedAt = displayTimestampFormatter.string(from: date)
        let markdown = """
        # Transcript

        Recorded: \(recordedAt)

        \(text)
        """
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func ensureTranscriptsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = appSupport
            .appendingPathComponent("Yaprflow", isDirectory: true)
            .appendingPathComponent(transcriptsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func uniqueTranscriptURL(in directory: URL, date: Date) -> URL {
        let baseName = "transcript-\(filenameTimestampFormatter.string(from: date))"
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension("md")
            suffix += 1
        }
        return candidate
    }

    private static let filenameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    private static let displayTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
