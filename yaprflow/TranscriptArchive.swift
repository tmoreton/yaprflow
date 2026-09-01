import Foundation

struct TranscriptArchiveDocument {
    let url: URL
    let recordedAt: Date
    let transcript: String
    let generatedTitle: String?
    let topic: String?
    let generatedDescription: String?

    var needsGeneratedMetadata: Bool {
        generatedTitle == nil || topic == nil || generatedDescription == nil
    }

    static func load(from url: URL) throws -> TranscriptArchiveDocument {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let fallbackDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        return TranscriptArchiveDocument(
            url: url,
            recordedAt: recordedDate(from: contents) ?? fallbackDate,
            transcript: transcriptBody(from: contents),
            generatedTitle: metadataValue(named: "ai_title", in: contents),
            topic: metadataValue(named: "ai_topic", in: contents),
            generatedDescription: metadataValue(named: "ai_description", in: contents)
        )
    }

    private static func recordedDate(from markdown: String) -> Date? {
        guard let value = metadataValue(named: "recorded_at", in: markdown) else { return nil }
        return fractionalISOFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func metadataValue(named key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else {
            return nil
        }

        let prefix = "\(key):"
        guard let line = lines[1..<closingIndex].first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }) else {
            return nil
        }

        var value = line
            .trimmingCharacters(in: .whitespaces)
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        let unescaped = value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unescaped.isEmpty ? nil : unescaped
    }

    private static func transcriptBody(from markdown: String) -> String {
        guard let heading = markdown.range(of: "# Transcript") else {
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines = markdown[heading.upperBound...]
            .components(separatedBy: .newlines)

        while let first = lines.first {
            let line = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty
                || line.hasPrefix("Recorded:")
                || line.hasPrefix("Mode:")
                || line.hasPrefix("Source:") {
                lines.removeFirst()
            } else {
                break
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct TranscriptArchiveChange {
    let oldURL: URL
    let newURL: URL
}

extension Notification.Name {
    static let yaprflowTranscriptArchiveChanged = Notification.Name(
        "yaprflow.transcriptArchive.changed"
    )
}
