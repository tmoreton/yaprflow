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
    private static let autoPasteModeKey = "yaprflow.autoPasteMode"
    private static let soundEffectsEnabledKey = "yaprflow.soundEffectsEnabled"
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

    /// When `true`, the final transcript is auto-pasted into the focused text
    /// field via a synthesized ⌘V (in addition to landing on the clipboard).
    /// Gated at the paste site on Accessibility permission, secure-input
    /// state, and a focus-PID match captured at recording start. Defaults to
    /// off so existing users aren't surprised by injected keystrokes.
    @Published var autoPasteMode: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteMode, forKey: Self.autoPasteModeKey)
        }
    }

    /// When `true`, play a short system sound on recording start (Pop) and
    /// stop (Tink). Defaults to on — chimes are a small but useful signal that
    /// the mic is actually live, especially on flaky hotkeys.
    @Published var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Self.soundEffectsEnabledKey)
        }
    }

    /// Live input audio level, normalized to 0…1. Driven from
    /// `TranscriptionController.feed()` at each PCM buffer (~50 Hz at the
    /// engine's default tap size). Consumed by the overlay's bouncing-bar
    /// visualizer; safe to leave at 0 outside of an active session.
    @Published var inputLevel: Float = 0

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
        if let stored = UserDefaults.standard.object(forKey: Self.autoPasteModeKey) as? Bool {
            self.autoPasteMode = stored
        } else {
            self.autoPasteMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.soundEffectsEnabledKey) as? Bool {
            self.soundEffectsEnabled = stored
        } else {
            self.soundEffectsEnabled = true
        }
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
