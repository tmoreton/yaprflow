import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "GlobalHotkey")

@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    nonisolated(unsafe) static var onFire: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregisterHotKey()
        guard installEventHandlerIfNeeded() else { return false }

        let hotKeyID = EventHotKeyID(signature: 0x59_50_72_66 /* 'YPrf' */, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            log.info("Registered global hotkey keyCode=\(keyCode, privacy: .public) modifiers=\(modifiers, privacy: .public)")
            return true
        } else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            return false
        }
    }

    func unregister() {
        unregisterHotKey()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                let handler = GlobalHotkey.onFire
                DispatchQueue.main.async { handler?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            log.error("InstallEventHandler failed: \(status, privacy: .public)")
        }
        return status == noErr
    }
}
