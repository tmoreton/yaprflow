import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "AutoPaste")

/// Synthesizes ⌘V into the currently-focused text field on behalf of the user.
///
/// Lives in the app source — NOT in a Hammerspoon clipboard-watcher — so the
/// call site can gate on the recording session's captured focus PID and the
/// pasteboard write it just performed, instead of guessing from
/// `pasteboard.changeCount` deltas.
@MainActor
enum AutoPaste {
    /// Re-checked on every call; TCC entries can be revoked at any time and
    /// ad-hoc signed builds (every `dev-build.sh` iteration) get a fresh code
    /// directory hash, which typically invalidates the existing AX grant.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the macOS "<App> would like to control this computer using
    /// accessibility features" prompt. The system only presents it on the
    /// FIRST call per (app, user); after a denial this returns false silently
    /// and the user has to grant manually in System Settings → Privacy &
    /// Security → Accessibility. Caller should treat the return value as the
    /// best current read of trust state, not as "the user just answered."
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [promptKey: kCFBooleanTrue!] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Opens the Accessibility pane directly so a user who already denied can
    /// flip the switch. Used by the menu item when state is "Needs Permission".
    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    /// True when macOS secure event input is active — typically a Terminal
    /// sudo prompt, FileVault unlock, or the lock screen mid-wake. Synthesized
    /// key events are silently dropped in this state, which would look like a
    /// silent auto-paste failure to the user. Better to bail and leave the
    /// transcript on the clipboard for manual paste.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Post ⌘V into the frontmost app. Caller is responsible for:
    ///   1. Verifying the pasteboard write succeeded.
    ///   2. Verifying focus is still on the intended target (PID match).
    ///   3. Verifying `hasAccessibility` and `!isSecureInputEnabled`.
    ///
    /// Uses `.privateState` event source so the synthesized event does NOT
    /// pick up the current physical HID modifier state. Without this, a hold-
    /// to-talk chord like Ctrl+Opt+F13 released a few ms before the paste can
    /// bleed Ctrl and Opt into the event and produce ⌘⌃⌥V in the target app.
    /// Flags are set explicitly on both keyDown and keyUp because some apps
    /// inspect modifier state on the up event too.
    static func sendCmdV() {
        guard let source = CGEventSource(stateID: .privateState) else {
            log.error("CGEventSource(.privateState) returned nil")
            return
        }
        let v = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
            let up   = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else {
            log.error("CGEvent keyboardEvent creation failed")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // `.cghidEventTap` is the standard injection point for cross-app
        // paste; the event is delivered at the HID layer and routed by the
        // window server like a real keystroke. `.cgAnnotatedSessionEventTap`
        // was considered and rejected: that tap sits AFTER session annotation
        // and is intended for monitoring, not for posting events into other
        // apps.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
