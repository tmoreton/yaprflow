@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import OSLog

private let inputAutomationLog = Logger(
    subsystem: "com.tmoreton.yaprflow",
    category: "InputAutomation"
)

enum AutomaticPasteResult {
    case disabled
    case pasted
    case permissionRequired
    case failed
}

@MainActor
enum InputAutomation {
    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    static var hasPostEventAccess: Bool {
        CGPreflightPostEventAccess()
    }

    static func requestAccessibilityAccess() {
        guard !hasAccessibilityAccess else { return }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestPostEventAccess() {
        guard !hasPostEventAccess else { return }
        _ = CGRequestPostEventAccess()
    }

    static func pasteIfEnabled() async -> AutomaticPasteResult {
        guard AppState.shared.isAutoPasteEnabled else { return .disabled }
        guard hasPostEventAccess else {
            requestPostEventAccess()
            inputAutomationLog.warning("Auto-paste is waiting for event-posting access")
            return .permissionRequired
        }

        // Give the destination app a moment to observe the new pasteboard
        // contents before delivering Command-V.
        try? await Task.sleep(for: .milliseconds(60))

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
              )
        else {
            inputAutomationLog.error("Could not create Command-V events")
            return .failed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(8))
        keyUp.post(tap: .cghidEventTap)
        inputAutomationLog.info("Pasted transcript into the frontmost application")
        return .pasted
    }
}
