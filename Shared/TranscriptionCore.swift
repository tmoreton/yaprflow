import Foundation

/// The language prompt applied to every recognition stream in one recording.
/// Keep this list limited to the locales NVIDIA classifies as working without
/// adaptation; the model also contains internal prompts for fine-tuning-only
/// locales that Yaprflow does not present as supported choices.
public enum SpeechLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case spanishUS = "es-US"
    case spanishSpain = "es-ES"
    case frenchFrance = "fr-FR"
    case frenchCanada = "fr-CA"
    case italian = "it-IT"
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case dutch = "nl-NL"
    case german = "de-DE"
    case turkish = "tr-TR"
    case russian = "ru-RU"
    case arabic = "ar-AR"
    case hindi = "hi-IN"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case vietnamese = "vi-VN"
    case ukrainian = "uk-UA"
    case polish = "pl-PL"
    case swedish = "sv-SE"
    case czech = "cs-CZ"
    case norwegianBokmal = "nb-NO"
    case danish = "da-DK"
    case bulgarian = "bg-BG"
    case finnish = "fi-FI"
    case croatian = "hr-HR"
    case slovak = "sk-SK"
    case chineseSimplified = "zh-CN"
    case hungarian = "hu-HU"
    case romanian = "ro-RO"
    case estonian = "et-EE"

    public static let defaultSelection: Self = .englishUS

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .englishUS: return "English (United States)"
        case .englishUK: return "English (United Kingdom)"
        case .spanishUS: return "Spanish (United States)"
        case .spanishSpain: return "Spanish (Spain)"
        case .frenchFrance: return "French (France)"
        case .frenchCanada: return "French (Canada)"
        case .italian: return "Italian"
        case .portugueseBrazil: return "Portuguese (Brazil)"
        case .portuguesePortugal: return "Portuguese (Portugal)"
        case .dutch: return "Dutch"
        case .german: return "German"
        case .turkish: return "Turkish"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .vietnamese: return "Vietnamese"
        case .ukrainian: return "Ukrainian"
        case .polish: return "Polish"
        case .swedish: return "Swedish"
        case .czech: return "Czech"
        case .norwegianBokmal: return "Norwegian Bokmål"
        case .danish: return "Danish"
        case .bulgarian: return "Bulgarian"
        case .finnish: return "Finnish"
        case .croatian: return "Croatian"
        case .slovak: return "Slovak"
        case .chineseSimplified: return "Mandarin (Simplified Chinese)"
        case .hungarian: return "Hungarian"
        case .romanian: return "Romanian"
        case .estonian: return "Estonian"
        }
    }

    /// Missing and unknown stored values deliberately choose English instead
    /// of automatic detection. This also gives existing installs the safer
    /// default the first time they run a build with this preference.
    public static func selection(fromPersistedValue value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? defaultSelection
    }
}

public struct BundledModelFile: Equatable, Sendable {
    public let name: String
    public let byteCount: Int64

    public init(name: String, byteCount: Int64) {
        self.name = name
        self.byteCount = byteCount
    }
}

/// Runtime names and byte-level integrity expectations shared by both apps.
/// Cryptographic verification for fetched and release assets lives in the
/// checked-in scripts/model-checksums.sha256 manifest.
public enum BundledModelInventory {
    /// macOS direct-distribution model. Keep this separate from `speechFiles`:
    /// the iOS target still uses the smaller streaming ONNX export.
    public static let parakeetSpeechDirectory =
        "Models/parakeet-tdt-0.6b-v3"
    public static let parakeetSpeechFiles = [
        BundledModelFile(name: "Preprocessor.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        BundledModelFile(name: "Preprocessor.mlmodelc/coremldata.bin", byteCount: 486),
        BundledModelFile(name: "Preprocessor.mlmodelc/metadata.json", byteCount: 2_841),
        BundledModelFile(name: "Preprocessor.mlmodelc/model.mil", byteCount: 28_181),
        BundledModelFile(name: "Preprocessor.mlmodelc/weights/weight.bin", byteCount: 491_072),
        BundledModelFile(name: "Encoder.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        BundledModelFile(name: "Encoder.mlmodelc/coremldata.bin", byteCount: 485),
        BundledModelFile(name: "Encoder.mlmodelc/metadata.json", byteCount: 2_921),
        BundledModelFile(name: "Encoder.mlmodelc/model.mil", byteCount: 959_769),
        BundledModelFile(name: "Encoder.mlmodelc/weights/weight.bin", byteCount: 445_187_200),
        BundledModelFile(name: "Decoder.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        BundledModelFile(name: "Decoder.mlmodelc/coremldata.bin", byteCount: 554),
        BundledModelFile(name: "Decoder.mlmodelc/metadata.json", byteCount: 3_427),
        BundledModelFile(name: "Decoder.mlmodelc/model.mil", byteCount: 13_110),
        BundledModelFile(name: "Decoder.mlmodelc/weights/weight.bin", byteCount: 23_604_992),
        BundledModelFile(name: "JointDecision.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        BundledModelFile(name: "JointDecision.mlmodelc/coremldata.bin", byteCount: 534),
        BundledModelFile(name: "JointDecision.mlmodelc/metadata.json", byteCount: 2_936),
        BundledModelFile(name: "JointDecision.mlmodelc/model.mil", byteCount: 9_723),
        BundledModelFile(name: "JointDecision.mlmodelc/weights/weight.bin", byteCount: 12_642_764),
        BundledModelFile(name: "parakeet_vocab.json", byteCount: 151_122),
    ]

    /// iOS streaming model inventory.
    public static let speechDirectory =
        "Models/nemotron-3.5-asr-streaming-0.6b-1120ms"
    public static let speechFiles = [
        BundledModelFile(name: "encoder.int8.onnx", byteCount: 657_601_521),
        BundledModelFile(name: "decoder.int8.onnx", byteCount: 14_978_075),
        BundledModelFile(name: "joiner.int8.onnx", byteCount: 9_504_438),
        BundledModelFile(name: "tokens.txt", byteCount: 131_440),
    ]

    public static let voiceDetectorDirectory = "Models/silero-vad"
    public static let voiceDetectorModel =
        "silero-vad-unified-256ms-v6.0.0.mlmodelc"
}

/// Keeps streamed audio addressable by the absolute sample indexes emitted by
/// the VAD while allowing samples behind the active segment to be discarded.
/// Storage is compacted in batches so long sessions stay bounded without an
/// O(n) prefix move on every audio callback.
public struct RollingSessionAudio: Sendable {
    private var storage: [Float] = []
    private var head = 0

    public private(set) var startIndex = 0

    public init() {}

    public var endIndex: Int { startIndex + storage.count - head }
    public var isEmpty: Bool { head == storage.count }
    public var retainedSampleCount: Int { storage.count - head }

    public mutating func reset(keepingCapacity: Bool) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
        startIndex = 0
    }

    public mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
    }

    public func samples(from requestedStart: Int, to requestedEnd: Int) -> [Float] {
        let lower = max(startIndex, min(requestedStart, endIndex))
        let upper = max(lower, min(requestedEnd, endIndex))
        guard upper > lower else { return [] }

        let lowerOffset = head + lower - startIndex
        let upperOffset = head + upper - startIndex
        return Array(storage[lowerOffset..<upperOffset])
    }

    public mutating func discard(before requestedIndex: Int) {
        let discardEnd = max(startIndex, min(requestedIndex, endIndex))
        let discardCount = discardEnd - startIndex
        guard discardCount > 0 else { return }

        head += discardCount
        startIndex = discardEnd

        if head >= 64_000, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

/// Shared transcript-boundary behavior for the macOS and iOS streaming paths.
public enum TranscriptSegments {
    /// Append a finalized segment, optionally removing the repeated words from
    /// the short audio overlap used at forced segment boundaries.
    public static func appending(
        _ segment: String,
        to existing: String,
        deduplicatingLeadingOverlap: Bool,
        maximumOverlapWords: Int = 12
    ) -> String {
        guard !segment.isEmpty else { return existing }
        guard !existing.isEmpty else { return segment }
        guard deduplicatingLeadingOverlap else {
            return joining(existing, segment)
        }

        if usesCompactBoundary(between: existing, and: segment) {
            let remainder = droppingCompactLeadingOverlap(
                from: segment,
                alreadyConfirmedIn: existing,
                maximumOverlapCharacters: max(0, maximumOverlapWords * 4)
            )
            guard !remainder.isEmpty else { return existing }
            return joining(existing, remainder)
        }

        let existingWords = existing.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let segmentWords = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let maximumOverlap = min(
            max(0, maximumOverlapWords),
            min(existingWords.count, segmentWords.count)
        )
        var overlap = 0

        if maximumOverlap > 0 {
            for count in stride(from: maximumOverlap, through: 1, by: -1) {
                let existingStart = existingWords.count - count
                let oldBoundary = existingWords[existingStart...].map(boundaryToken)
                let newBoundary = segmentWords.prefix(count).map(boundaryToken)
                if !oldBoundary.contains(""), oldBoundary == newBoundary {
                    overlap = count
                    break
                }
            }
        }

        let remainder = segmentWords.dropFirst(overlap)
        guard !remainder.isEmpty else { return existing }
        return joining(existing, remainder.joined(separator: " "))
    }

    public static func combining(confirmed: String, volatile: String) -> String {
        switch (confirmed.isEmpty, volatile.isEmpty) {
        case (true, true): return ""
        case (false, true): return confirmed
        case (true, false): return volatile
        case (false, false): return joining(confirmed, volatile)
        }
    }

    public static func capitalizingFirstLetter(in text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        var result = text
        result.replaceSubrange(index...index, with: text[index].uppercased())
        return result
    }

    private static func boundaryToken(_ word: String) -> String {
        String(
            word.lowercased().filter {
                $0.isLetter || $0.isNumber || $0 == "'"
            }
        )
    }

    /// Chinese, Japanese, and Thai do not use inter-word whitespace the way
    /// Latin-script dictation does. Determine spacing from the scripts nearest
    /// the segment boundary while ignoring punctuation and numbers.
    private static func usesCompactBoundary(
        between existing: String,
        and segment: String
    ) -> Bool {
        let trailingStyle = boundaryStyle(in: existing, fromEnd: true)
        let leadingStyle = boundaryStyle(in: segment, fromEnd: false)

        switch (trailingStyle, leadingStyle) {
        case (.compact?, .compact?): return true
        case (.compact?, nil), (nil, .compact?): return true
        default: return false
        }
    }

    private enum BoundaryStyle {
        case compact
        case spaced
    }

    private static func boundaryStyle(
        in text: String,
        fromEnd: Bool
    ) -> BoundaryStyle? {
        let characters: AnySequence<Character> = fromEnd
            ? AnySequence(text.reversed())
            : AnySequence(text)

        for character in characters where character.isLetter {
            return isCompactScript(character) ? .compact : .spaced
        }
        return nil
    }

    private static func isCompactScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0E7F,       // Thai
                 0x3040...0x30FF,       // Hiragana and Katakana
                 0x31F0...0x31FF,       // Katakana phonetic extensions
                 0x3400...0x4DBF,       // CJK Extension A
                 0x4E00...0x9FFF,       // CJK unified ideographs
                 0xF900...0xFAFF,       // CJK compatibility ideographs
                 0xFF66...0xFF9D,       // Half-width Katakana
                 0x20000...0x2FA1F:     // Supplementary CJK ideographs
                return true
            default:
                return false
            }
        }
    }

    private struct CompactBoundaryUnit {
        let token: String
        let startIndex: String.Index
    }

    private static func droppingCompactLeadingOverlap(
        from segment: String,
        alreadyConfirmedIn existing: String,
        maximumOverlapCharacters: Int
    ) -> String {
        guard maximumOverlapCharacters > 0 else { return segment }

        let existingUnits = compactBoundaryUnits(in: existing)
        let segmentUnits = compactBoundaryUnits(in: segment)
        let maximumOverlap = min(
            maximumOverlapCharacters,
            min(existingUnits.count, segmentUnits.count)
        )
        guard maximumOverlap > 0 else { return segment }

        var overlap = 0
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            let existingStart = existingUnits.count - count
            let oldBoundary = existingUnits[existingStart...].map(\.token)
            let newBoundary = segmentUnits.prefix(count).map(\.token)
            if oldBoundary == newBoundary {
                overlap = count
                break
            }
        }
        guard overlap > 0 else { return segment }
        guard overlap < segmentUnits.count else { return "" }

        return String(segment[segmentUnits[overlap].startIndex...])
    }

    private static func compactBoundaryUnits(in text: String) -> [CompactBoundaryUnit] {
        text.indices.compactMap { index in
            let token = boundaryToken(String(text[index]))
            guard !token.isEmpty else { return nil }
            return CompactBoundaryUnit(token: token, startIndex: index)
        }
    }

    private static func joining(_ existing: String, _ segment: String) -> String {
        guard existing.last?.isWhitespace != true,
              segment.first?.isWhitespace != true,
              !beginsWithClosingPunctuation(segment),
              !usesCompactBoundary(between: existing, and: segment) else {
            return existing + segment
        }
        return existing + " " + segment
    }

    private static func beginsWithClosingPunctuation(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return ",.!?;:%)]}\u{00BB}\u{2019}\u{201D}\u{3001}\u{3002}\u{FF01}\u{FF09}\u{FF0C}\u{FF1A}\u{FF1B}\u{FF1F}\u{3009}\u{300B}\u{300D}\u{300F}\u{3011}".contains(first)
    }
}

/// A single lifecycle value replaces combinations of independent booleans
/// that can otherwise represent impossible recording states.
public enum RecordingLifecyclePhase: Equatable, Hashable, Sendable {
    case idle
    case starting(UInt)
    case recording(UInt)
    case stopping(UInt)
}
