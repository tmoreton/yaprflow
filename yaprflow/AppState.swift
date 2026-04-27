import Combine
import SwiftUI

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case finishing
    case correcting(String)
    case summarizing  // New: on-demand summary in progress
    case copied
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private static let streamingModeKey = "yaprflow.streamingMode"
    private static let grammarModeKey = "yaprflow.grammarMode"
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

    /// When `true`, run the finalized transcript through an on-device MLX LLM
    /// for grammar / punctuation correction. The original text is still copied
    /// to the clipboard immediately so the workflow doesn't block.
    @Published var grammarMode: Bool {
        didSet {
            UserDefaults.standard.set(grammarMode, forKey: Self.grammarModeKey)
        }
    }

    /// Most recent finalized transcript. Persisted so it survives restarts and
    /// can be re-copied from the menu bar after the clipboard has been replaced.
    @Published var lastTranscript: String {
        didSet {
            UserDefaults.standard.set(lastTranscript, forKey: Self.lastTranscriptKey)
        }
    }

    /// The raw transcript before grammar correction. Empty when grammar mode
    /// is off or hasn't run yet.
    @Published var lastOriginalTranscript: String = ""

    private init() {
        if let stored = UserDefaults.standard.object(forKey: Self.streamingModeKey) as? Bool {
            self.streamingMode = stored
        } else {
            self.streamingMode = true
        }
        if let stored = UserDefaults.standard.object(forKey: Self.grammarModeKey) as? Bool {
            self.grammarMode = stored
        } else {
            self.grammarMode = false
        }
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
