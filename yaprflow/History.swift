import AppKit
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
    @Published var selection: URL?
    @Published private(set) var errorMessage: String?

    var selectedItem: TranscriptHistoryItem? {
        items.first { $0.id == selection }
    }

    func refresh(selectLatest: Bool = false) {
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

            if selectLatest || !items.contains(where: { $0.id == selection }) {
                selection = items.first?.id
            }
            errorMessage = nil
        } catch {
            items = []
            selection = nil
            errorMessage = error.localizedDescription
        }
    }

    func copySelected() {
        guard let selectedItem, !selectedItem.transcript.isEmpty else { return }
        copyToClipboard(selectedItem.transcript)
    }

    private func copyToClipboard(_ transcript: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    func openSelected() {
        guard let selectedItem else { return }
        NSWorkspace.shared.open(selectedItem.url)
    }

    func revealSelection() {
        if let selectedItem {
            NSWorkspace.shared.activateFileViewerSelecting([selectedItem.url])
        } else if let directory = try? AppState.shared.transcriptsDirectory() {
            NSWorkspace.shared.open(directory)
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
            if selection == item.id {
                selection = items.first?.id
            }
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

    func handleArchiveChange(_ notification: Notification) {
        if let change = notification.object as? TranscriptArchiveChange,
           selection == change.oldURL {
            selection = change.newURL
        }
        refresh()
    }
}
