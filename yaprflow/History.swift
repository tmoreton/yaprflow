import AppKit
import Combine
import SwiftUI

struct TranscriptHistoryItem: Identifiable, Hashable {
    let url: URL
    let recordedAt: Date
    let transcript: String
    let generatedTitle: String?
    let topic: String?
    let generatedDescription: String?

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
                    generatedDescription: document.generatedDescription
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

    func selectAndCopy(_ item: TranscriptHistoryItem) {
        selection = item.id
        guard !item.transcript.isEmpty else { return }
        copyToClipboard(item.transcript)
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

    func handleArchiveChange(_ notification: Notification) {
        if let change = notification.object as? TranscriptArchiveChange,
           selection == change.oldURL {
            selection = change.newURL
        }
        refresh()
    }
}

struct HistoryView: View {
    @StateObject private var model = TranscriptHistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh")
            }

            Divider()

            if model.items.isEmpty {
                emptyState
            } else {
                transcriptList
            }

            Divider()

            HStack(spacing: 8) {
                statusText
                Spacer()

                Button("Folder", systemImage: "folder") {
                    model.revealSelection()
                }

                Button("Open") {
                    model.openSelected()
                }
                .disabled(model.selectedItem == nil)

                Button("Copy", systemImage: "doc.on.clipboard") {
                    model.copySelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedItem?.transcript.isEmpty != false)
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 350)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refresh()
            TranscriptMetadataEnricher.shared.enqueueMissingTranscripts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaprflowTranscriptArchiveChanged)) {
            model.handleArchiveChange($0)
        }
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.items) { item in
                    Button {
                        model.selectAndCopy(item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(item.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)

                                    Spacer(minLength: 8)

                                    Text(item.dateDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                if let topic = item.topic {
                                    Text(topic)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Text(item.preview)
                                    .font(.caption)
                                    .foregroundStyle(item.topic == nil ? .secondary : .tertiary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            model.selection == item.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No transcripts yet")
                .font(.callout.weight(.medium))
            Text("Completed transcripts will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: some View {
        Group {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text("\(model.items.count) \(model.items.count == 1 ? "item" : "items")")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

@MainActor
enum HistoryWindowController {
    static let shared = FeatureWindowController(
        title: "History",
        contentSize: NSSize(width: 540, height: 430),
        minimumSize: NSSize(width: 480, height: 350)
    ) {
        HistoryView()
    }
}
