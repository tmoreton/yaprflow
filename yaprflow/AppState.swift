import Combine
import Foundation
import SwiftUI

enum DictationMode: String, CaseIterable {
    case exact
    case polished

    var displayName: String {
        switch self {
        case .exact: return "Exact"
        case .polished: return "Polished"
        }
    }

    var archiveValue: String { rawValue }
}

struct TranscriptProcessingResult {
    let text: String
    let vocabularyReplacementCount: Int
}

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
    private static let dictationModeKey = "yaprflow.dictationMode"
    private static let transcriptsFolderName = "Transcripts"
    private static let vocabularyFileName = "Vocabulary.md"

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey
    @Published var dictationMode: DictationMode {
        didSet {
            UserDefaults.standard.set(dictationMode.rawValue, forKey: Self.dictationModeKey)
        }
    }

    /// Most recent finalized transcript. Persisted so it survives restarts and
    /// can be re-copied from the menu bar after the clipboard has been replaced.
    @Published var lastTranscript: String {
        didSet {
            UserDefaults.standard.set(lastTranscript, forKey: Self.lastTranscriptKey)
        }
    }

    private init() {
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
        self.dictationMode = .polished
        UserDefaults.standard.set(DictationMode.polished.rawValue, forKey: Self.dictationModeKey)
    }

    /// Store the newest transcript for quick re-copy and persist each finalized
    /// transcript as a standalone Markdown file.
    func recordTranscript(
        _ text: String,
        sourceApplication: String?,
        vocabularyReplacementCount: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? Self.writeTranscriptMarkdown(
            trimmed,
            mode: dictationMode,
            sourceApplication: sourceApplication,
            vocabularyReplacementCount: vocabularyReplacementCount
        )
        lastTranscript = trimmed
    }

    func processTranscript(_ raw: String) -> TranscriptProcessingResult {
        let modeProcessed: String
        switch dictationMode {
        case .exact:
            modeProcessed = Self.trimTranscript(raw)
        case .polished:
            modeProcessed = Self.polishTranscript(raw)
        }

        return Self.applyVocabulary(to: modeProcessed)
    }

    func transcriptsDirectory() throws -> URL {
        try Self.ensureTranscriptsDirectory()
    }

    func vocabularyFileURL() throws -> URL {
        try Self.ensureVocabularyFile()
    }

    func vocabularyEntryCount() -> Int {
        (try? Self.loadVocabularyReplacements().count) ?? 0
    }

    private static func writeTranscriptMarkdown(
        _ text: String,
        mode: DictationMode,
        sourceApplication: String?,
        vocabularyReplacementCount: Int
    ) throws {
        let directory = try ensureTranscriptsDirectory()
        let date = Date()
        let fileURL = uniqueTranscriptURL(in: directory, date: date)
        let recordedAt = displayTimestampFormatter.string(from: date)
        let isoRecordedAt = isoTimestampFormatter.string(from: date)
        let sourceValue = normalizedMetadataValue(sourceApplication)
        let markdown = """
        ---
        recorded_at: "\(isoRecordedAt)"
        mode: "\(mode.archiveValue)"
        source_app: "\(escapedYAMLValue(sourceValue))"
        vocabulary_replacements: \(vocabularyReplacementCount)
        ---

        # Transcript

        Recorded: \(recordedAt)
        Mode: \(mode.displayName)
        Source: \(sourceValue)

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

    private static func ensureVocabularyFile() throws -> URL {
        let directory = try ensureAppSupportDirectory()
        let url = directory.appendingPathComponent(vocabularyFileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }

        let template = """
        # Yaprflow Vocabulary
        #
        # Add one replacement per line:
        # spoken phrase => preferred spelling
        #
        # Examples:
        # yapper flow => Yaprflow
        # swift you eye => SwiftUI
        # parakeet t d t => Parakeet TDT

        """
        try template.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func ensureAppSupportDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = appSupport.appendingPathComponent("Yaprflow", isDirectory: true)
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

    private static func normalizedMetadataValue(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private static func escapedYAMLValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let fillerWordRegex: NSRegularExpression = {
        let pattern = #"(?i)\b(?:u+h+m*|u+m+h*|e+r+h*|a+h+m*|hmm+|mm+|mhm+)\b[,\.]?\s*"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func trimTranscript(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func polishTranscript(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        var text = fillerWordRegex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: range,
            withTemplate: ""
        )
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, ",.;:!?".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private struct VocabularyReplacement {
        let spoken: String
        let preferred: String
    }

    private static func applyVocabulary(to text: String) -> TranscriptProcessingResult {
        guard !text.isEmpty, let replacements = try? loadVocabularyReplacements(), !replacements.isEmpty else {
            return TranscriptProcessingResult(text: text, vocabularyReplacementCount: 0)
        }

        var processed = text
        var totalReplacements = 0

        for replacement in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: replacement.spoken)
            let pattern = #"(?i)\b"# + escaped + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let range = NSRange(processed.startIndex..., in: processed)
            let matches = regex.numberOfMatches(in: processed, options: [], range: range)
            guard matches > 0 else { continue }

            processed = regex.stringByReplacingMatches(
                in: processed,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.preferred)
            )
            totalReplacements += matches
        }

        return TranscriptProcessingResult(
            text: processed,
            vocabularyReplacementCount: totalReplacements
        )
    }

    private static func loadVocabularyReplacements() throws -> [VocabularyReplacement] {
        let url = try ensureVocabularyFile()
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .components(separatedBy: .newlines)
            .compactMap(parseVocabularyLine)
    }

    private static func parseVocabularyLine(_ rawLine: String) -> VocabularyReplacement? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        for separator in ["=>", "->", "="] {
            guard let range = line.range(of: separator) else { continue }
            let spoken = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let preferred = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !preferred.isEmpty else { return nil }
            return VocabularyReplacement(spoken: spoken, preferred: preferred)
        }

        return nil
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

    private static let isoTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
