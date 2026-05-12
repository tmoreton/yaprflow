import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "GlobalHotkey")

@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Fires on key-down. Used by tap-to-toggle mode (calls toggle()).
    nonisolated(unsafe) static var onPressed: (@Sendable () -> Void)?

    /// Fires on key-up. Used by hold-to-talk mode (calls setActive(false)).
    /// Tap-to-toggle leaves this nil.
    nonisolated(unsafe) static var onReleased: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregisterHotKey()
        installEventHandlerIfNeeded()

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
        } else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
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

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                let kind = GetEventKind(event)
                let handler: (@Sendable () -> Void)?
                switch Int(kind) {
                case kEventHotKeyPressed:
                    handler = GlobalHotkey.onPressed
                case kEventHotKeyReleased:
                    handler = GlobalHotkey.onReleased
                default:
                    handler = nil
                }
                DispatchQueue.main.async { handler?() }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandlerRef
        )
    }
}
