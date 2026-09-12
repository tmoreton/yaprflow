import Foundation
import NaturalLanguage

/// Conservative cleanup for recognizer output.
///
/// Some filler spellings are ordinary words in other languages (for example,
/// Portuguese "um" and German "er"). English-only transformations therefore
/// run only when Apple's on-device language recognizer identifies the complete
/// transcript as English with reasonable confidence. Language-neutral trimming
/// remains safe for every transcript.
public enum TranscriptPolishing {
    public static func polish(
        _ raw: String,
        normalizingEnglishAllCaps: Bool = false
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isConfidentlyEnglish(text) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        text = fillerWordRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, ",.;:!?".contains(first) {
            text = String(text.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if normalizingEnglishAllCaps,
           text.rangeOfCharacter(from: .uppercaseLetters) != nil,
           text.rangeOfCharacter(from: .lowercaseLetters) == nil
        {
            text = text.lowercased()
            let lowercaseRange = NSRange(text.startIndex..., in: text)
            text = standaloneIRegex.stringByReplacingMatches(
                in: text,
                options: [],
                range: lowercaseRange,
                withTemplate: "I"
            )
        }

        return text
    }

    private static func isConfidentlyEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard recognizer.dominantLanguage == .english else { return false }
        return recognizer.languageHypotheses(withMaximum: 3)[.english, default: 0] >= 0.5
    }

    private static let fillerWordRegex: NSRegularExpression = {
        let pattern = #"(?i)\b(?:u+h+m*|u+m+h*|e+r+h*|a+h+m*|hmm+|mm+|mhm+)\b[,\.]?\s*"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let standaloneIRegex =
        try! NSRegularExpression(pattern: #"\bi\b"#)
}
