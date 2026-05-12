import AppKit
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "SoundEffects")

/// Tiny wrapper around system sounds for the start/stop chimes. macOS ships
/// these in `/System/Library/Sounds/`; `NSSound(named:)` finds them by basename
/// with no bundle weight on our side. Gated on `AppState.soundEffectsEnabled`
/// so users who find chimes annoying can silence them from the menu without
/// losing the rest of the visual feedback.
@MainActor
enum SoundEffect {
    case start
    case stop

    private var systemSoundName: String {
        switch self {
        // Soft wind puff — "we're starting" without the alert-like sharpness
        // of Pop. Friendlier ramp into recording.
        case .start: return "Blow"
        // Soft chime descent — clean "we're done" that pairs with the green
        // checkmark in the overlay.
        case .stop:  return "Glass"
        }
    }

    /// Fire-and-forget. Multiple back-to-back plays (e.g. user taps the hotkey
    /// twice fast in tap-to-toggle) overlap cleanly — `NSSound.play()` returns
    /// immediately and the audio path is independent of our recording pipeline.
    func play() {
        guard AppState.shared.soundEffectsEnabled else { return }
        guard let sound = NSSound(named: NSSound.Name(systemSoundName)) else {
            log.error("System sound \(self.systemSoundName, privacy: .public) not found")
            return
        }
        sound.play()
    }
}
