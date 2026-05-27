import Combine
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

    private static let historyKey = "yaprflow.history"
    private static let maxHistory = 3

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey

    /// Most recent finalized transcripts (newest first), capped at 3. Persists
    /// across restarts so the status-bar menu can offer them as quick re-copy
    /// items.
    @Published var history: [String] {
        didSet {
            UserDefaults.standard.set(history, forKey: Self.historyKey)
        }
    }

    private init() {
        self.history = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    /// Insert text at the head of history, dedup, cap at maxHistory.
    func recordTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = history.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        if next.count > Self.maxHistory {
            next = Array(next.prefix(Self.maxHistory))
        }
        history = next
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
    static let yaprflowHistoryChanged = Notification.Name("yaprflow.history.changed")
}
