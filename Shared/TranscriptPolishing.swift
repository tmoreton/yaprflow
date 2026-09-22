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

        for rule in spokenPunctuationRules {
            let punctuationRange = NSRange(text.startIndex..., in: text)
            text = rule.regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: punctuationRange,
                withTemplate: rule.replacement
            )
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

        return resolvingSpokenPunctuationMarkers(in: text)
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

    private struct SpokenPunctuationRule {
        let regex: NSRegularExpression
        let replacement: String

        init(_ pattern: String, replacement: String) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.replacement = replacement
        }
    }

    /// A private marker lets us capitalize only after punctuation the user
    /// explicitly dictated. That avoids changing casing after abbreviations or
    /// punctuation already supplied by the recognizer.
    private static let sentenceBreakMarker = "\u{E000}"

    private static let spokenPunctuationRules: [SpokenPunctuationRule] = [
        SpokenPunctuationRule(
            #"[ \t]+new paragraph\b(?![ \t]+(?:about|on|of|for|in)\b)[,.!?;:]?[ \t]*"#,
            replacement: "\n\n\(sentenceBreakMarker)"
        ),
        SpokenPunctuationRule(
            #"[ \t]+new line\b(?![ \t]+(?:of|from|for|products?|work|business|code)\b)[,.!?;:]?[ \t]*"#,
            replacement: "\n\(sentenceBreakMarker)"
        ),
        SpokenPunctuationRule(
            #"[ \t]+question mark\b(?![ \t]+(?:symbol|character|key|in|on|after|before|means|word)\b)[,.!?;:]?(?=[ \t\r\n]|$)"#,
            replacement: "?\(sentenceBreakMarker)"
        ),
        SpokenPunctuationRule(
            #"[ \t]+exclamation (?:point|mark)\b(?![ \t]+(?:symbol|character|key|in|on|after|before|means|word)\b)[,.!?;:]?(?=[ \t\r\n]|$)"#,
            replacement: "!\(sentenceBreakMarker)"
        ),
        SpokenPunctuationRule(
            #"[ \t]+(?:period|full stop)\b(?![ \t]+(?:of|in|between|during|where|when|after|before|from|for|was|is|that|which|called|means|symbol|word)\b)[,.!?;:]?(?=[ \t\r\n]|$)"#,
            replacement: ".\(sentenceBreakMarker)"
        ),
        SpokenPunctuationRule(
            #"[ \t]+semicolon\b(?![ \t]+(?:symbol|character|key|in|after|before|means|word)\b)[,.!?;:]?(?=[ \t\r\n]|$)"#,
            replacement: ";"
        ),
        SpokenPunctuationRule(
            #"[ \t]+colon\b(?![ \t]+(?:cancer|symbol|character|key|in|after|before|means|word)\b)[,.!?;:]?(?=[ \t\r\n]|$)"#,
            replacement: ":"
        ),
        SpokenPunctuationRule(
            #"[ \t]+comma\b(?![ \t]+(?:separated|delimited|splice|symbol|character|key|in|after|before|means|word)\b)[,.!?;:]?(?=[ \t\r\n]|$)"#,
            replacement: ","
        ),
    ]

    private static func resolvingSpokenPunctuationMarkers(in text: String) -> String {
        var result = ""
        var capitalizeNextLetter = false

        for character in text {
            if String(character) == sentenceBreakMarker {
                capitalizeNextLetter = true
                continue
            }

            if capitalizeNextLetter, character.isLetter {
                result.append(contentsOf: String(character).uppercased())
                capitalizeNextLetter = false
            } else {
                result.append(character)
                if capitalizeNextLetter,
                   !character.isWhitespace,
                   !character.isPunctuation
                {
                    capitalizeNextLetter = false
                }
            }
        }

        return result
    }
}
