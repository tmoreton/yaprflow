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

    private static let streamingModeKey = "yaprflow.streamingMode"
    private static let lastTranscriptKey = "yaprflow.lastTranscript"

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey

    /// When `true` (default), show live partials during dictation at the cost
    /// of slightly lower accuracy. When `false`, record silently and transcribe
    /// the full clip in one pass when the hotkey is released — more accurate
    /// for longer sentences, but no text appears until you stop.
    @Published var streamingMode: Bool {
        didSet {
            UserDefaults.standard.set(streamingMode, forKey: Self.streamingModeKey)
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
        if let stored = UserDefaults.standard.object(forKey: Self.streamingModeKey) as? Bool {
            self.streamingMode = stored
        } else {
            self.streamingMode = true
        }
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
