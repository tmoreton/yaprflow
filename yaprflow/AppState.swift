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

struct VocabularyReplacement {
    let spoken: String
    let preferred: String
}

/// Immutable text-processing rules captured at the beginning of a recording.
/// Keeping the compiled expressions here avoids reading Vocabulary.md and
/// rebuilding every regular expression for each streaming partial result.
struct TranscriptProcessor {
    private struct CompiledVocabularyReplacement {
        let regex: NSRegularExpression
        let preferredTemplate: String
    }

    let mode: DictationMode
    private let vocabulary: [CompiledVocabularyReplacement]

    init(mode: DictationMode, vocabulary: [VocabularyReplacement]) {
        self.mode = mode
        self.vocabulary = vocabulary.compactMap { replacement in
            let escaped = NSRegularExpression.escapedPattern(for: replacement.spoken)
            let pattern = #"(?i)\b"# + escaped + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return CompiledVocabularyReplacement(
                regex: regex,
                preferredTemplate: NSRegularExpression.escapedTemplate(
                    for: replacement.preferred
                )
            )
        }
    }

    func process(_ raw: String) -> TranscriptProcessingResult {
        let modeProcessed: String
        switch mode {
        case .exact:
            modeProcessed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        case .polished:
            modeProcessed = TranscriptPolishing.polish(raw)
        }

        guard !modeProcessed.isEmpty, !vocabulary.isEmpty else {
            return TranscriptProcessingResult(
                text: modeProcessed,
                vocabularyReplacementCount: 0
            )
        }

        var processed = modeProcessed
        var totalReplacements = 0
        for replacement in vocabulary {
            let range = NSRange(processed.startIndex..., in: processed)
            let matches = replacement.regex.numberOfMatches(
                in: processed,
                options: [],
                range: range
            )
            guard matches > 0 else { continue }

            processed = replacement.regex.stringByReplacingMatches(
                in: processed,
                options: [],
                range: range,
                withTemplate: replacement.preferredTemplate
            )
            totalReplacements += matches
        }

        return TranscriptProcessingResult(
            text: processed,
            vocabularyReplacementCount: totalReplacements
        )
    }

}

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case copied
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private static let lastTranscriptKey = "yaprflow.lastTranscript"
    private static let dictationModeKey = "yaprflow.dictationMode"
    private static let speechLanguageKey = "yaprflow.speechLanguage"
    private static let desktopPreviewEnabledKey = "yaprflow.desktopPreviewEnabled"
    private static let transcriptsFolderName = "Transcripts"
    private static let vocabularyFileName = "Vocabulary.md"
    private var shouldPersistDesktopPreviewPreference = true

    @Published var status: TranscriptionStatus = .idle
    @Published var audioLevel: Double = 0
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey
    @Published var isDesktopPreviewEnabled: Bool {
        didSet {
            if shouldPersistDesktopPreviewPreference {
                UserDefaults.standard.set(isDesktopPreviewEnabled, forKey: Self.desktopPreviewEnabledKey)
            }
        }
    }
    @Published var dictationMode: DictationMode {
        didSet {
            UserDefaults.standard.set(dictationMode.rawValue, forKey: Self.dictationModeKey)
        }
    }
    @Published var speechLanguage: SpeechLanguage {
        didSet {
            UserDefaults.standard.set(speechLanguage.rawValue, forKey: Self.speechLanguageKey)
        }
    }

    /// Most recent finalized transcript. Persisted so it survives restarts and
    /// remains available in History.
    @Published var lastTranscript: String {
        didSet {
            UserDefaults.standard.set(lastTranscript, forKey: Self.lastTranscriptKey)
        }
    }

    private init() {
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
        self.isDesktopPreviewEnabled = UserDefaults.standard.object(
            forKey: Self.desktopPreviewEnabledKey
        ) as? Bool ?? true
        self.dictationMode = UserDefaults.standard.string(forKey: Self.dictationModeKey)
            .flatMap(DictationMode.init(rawValue:)) ?? .polished
        self.speechLanguage = SpeechLanguage.selection(
            fromPersistedValue: UserDefaults.standard.string(forKey: Self.speechLanguageKey)
        )
    }

    /// Exercise preference-driven UI without changing the user's saved value.
    func setDesktopPreviewEnabledForSmokeTest(_ isEnabled: Bool) {
        shouldPersistDesktopPreviewPreference = false
        isDesktopPreviewEnabled = isEnabled
        shouldPersistDesktopPreviewPreference = true
    }

    /// Store the newest transcript for quick re-copy and persist each finalized
    /// transcript as a standalone Markdown file.
    func recordTranscript(
        _ text: String,
        mode: DictationMode? = nil,
        sourceApplication: String?,
        vocabularyReplacementCount: Int
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let recordedAt = Date()
        let recordedMode = mode ?? dictationMode

        // Preserve the quick re-copy value even if the Markdown archive cannot
        // be written, but propagate the disk error so the recording UI can be
        // honest about the partial success.
        lastTranscript = trimmed
        let fileURL = try Self.writeTranscriptMarkdown(
            trimmed,
            mode: recordedMode,
            sourceApplication: sourceApplication,
            vocabularyReplacementCount: vocabularyReplacementCount,
            recordedAt: recordedAt
        )
        TranscriptMetadataEnricher.shared.enqueue(
            url: fileURL,
            transcript: trimmed,
            recordedAt: recordedAt,
            automaticOutput: AIProviderSettings.shared.automaticDictationOutput
        )
    }

    func processTranscript(_ raw: String) -> TranscriptProcessingResult {
        makeTranscriptProcessor().process(raw)
    }

    func makeTranscriptProcessor(mode overrideMode: DictationMode? = nil) -> TranscriptProcessor {
        TranscriptProcessor(
            mode: overrideMode ?? dictationMode,
            vocabulary: (try? Self.loadVocabularyReplacements()) ?? []
        )
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
        vocabularyReplacementCount: Int,
        recordedAt date: Date
    ) throws -> URL {
        let directory = try ensureTranscriptsDirectory()
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
        return fileURL
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
        # dot net => .NET

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
