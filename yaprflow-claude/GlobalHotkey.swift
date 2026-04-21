import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    nonisolated(unsafe) fileprivate static var fireHandler: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    var onFire: (@Sendable () -> Void)? {
        get { Self.fireHandler }
        set { Self.fireHandler = newValue }
    }

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
            NSLog("RegisterEventHotKey failed: \(status)")
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
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                let handler = GlobalHotkey.fireHandler
                DispatchQueue.main.async { handler?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}
