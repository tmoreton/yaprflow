import Combine
import Foundation

struct TranscriptHistoryItem: Identifiable, Hashable {
    let url: URL
    let recordedAt: Date
    let transcript: String
    let generatedTitle: String?
    let topic: String?
    let generatedDescription: String?
    let automaticOutput: String?

    var id: URL { url }
    var title: String {
        generatedTitle ?? url.deletingPathExtension().lastPathComponent
    }

    var dateDescription: String {
        recordedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var preview: String {
        if let generatedDescription {
            return generatedDescription
        }

        let compact = transcript
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return compact.isEmpty ? "Empty transcript" : compact
    }
}

@MainActor
final class TranscriptHistoryModel: ObservableObject {
    @Published private(set) var items: [TranscriptHistoryItem] = []
    @Published private(set) var errorMessage: String?

    func refresh() {
        do {
            let directory = try AppState.shared.transcriptsDirectory()
            let keys: Set<URLResourceKey> = [.isRegularFileKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )

            items = urls.compactMap { url in
                guard url.pathExtension.lowercased() == "md" else { return nil }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile != false else { return nil }
                guard let document = try? TranscriptArchiveDocument.load(from: url) else { return nil }
                return TranscriptHistoryItem(
                    url: url,
                    recordedAt: document.recordedAt,
                    transcript: document.transcript,
                    generatedTitle: document.generatedTitle,
                    topic: document.topic,
                    generatedDescription: document.generatedDescription,
                    automaticOutput: document.automaticOutput
                )
            }
            .sorted { $0.recordedAt > $1.recordedAt }

            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    /// Moves a transcript archive to the Trash and updates the in-memory
    /// library immediately. The Trash keeps accidental deletions recoverable.
    @discardableResult
    func delete(_ item: TranscriptHistoryItem) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: item.url.path) {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: item.url,
                    resultingItemURL: &resultingURL
                )
            }
            items.removeAll { $0.id == item.id }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }

}
