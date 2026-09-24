import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "GlobalHotkey")

@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    nonisolated(unsafe) static var onFire: (@Sendable () -> Void)?
    nonisolated(unsafe) static var onMeetingNotesFire: (@Sendable () -> Void)?

    private var quickDictationHotKeyRef: EventHotKeyRef?
    private var meetingNotesHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var modifierOnlyConfig: HotkeyConfig?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var modifierOnlyIsDown = false
    private var modifierOnlyWasCombined = false

    private init() {}

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregisterHotKey(&quickDictationHotKeyRef)
        stopModifierOnlyMonitoring()

        let config = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)
        if config.isModifierOnly {
            modifierOnlyConfig = config
            let registered = startModifierOnlyMonitoring()
            if registered {
                log.info("Registered modifier-only dictation hotkey keyCode=\(keyCode, privacy: .public)")
            }
            return registered
        }

        guard let ref = makeHotKey(
            id: 1,
            keyCode: keyCode,
            modifiers: modifiers
        ) else { return false }
        quickDictationHotKeyRef = ref
        log.info("Registered dictation hotkey keyCode=\(keyCode, privacy: .public) modifiers=\(modifiers, privacy: .public)")
        return true
    }

    @discardableResult
    func registerMeetingNotes(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregisterHotKey(&meetingNotesHotKeyRef)
        guard let ref = makeHotKey(
            id: 2,
            keyCode: keyCode,
            modifiers: modifiers
        ) else { return false }
        meetingNotesHotKeyRef = ref
        log.info("Registered Meeting Notes hotkey keyCode=\(keyCode, privacy: .public) modifiers=\(modifiers, privacy: .public)")
        return true
    }

    private func makeHotKey(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> EventHotKeyRef? {
        guard installEventHandlerIfNeeded() else { return nil }
        let hotKeyID = EventHotKeyID(signature: 0x59_50_72_66 /* 'YPrf' */, id: id)
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
            return ref
        } else {
            log.error("RegisterEventHotKey id=\(id, privacy: .public) failed: \(status, privacy: .public)")
            return nil
        }
    }

    func unregister() {
        unregisterHotKey(&quickDictationHotKeyRef)
        unregisterHotKey(&meetingNotesHotKeyRef)
        stopModifierOnlyMonitoring()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func unregisterHotKey(_ hotKeyRef: inout EventHotKeyRef?) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func startModifierOnlyMonitoring() -> Bool {
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            Task { @MainActor in
                GlobalHotkey.shared.handleModifierOnlyEvent(event)
            }
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            Task { @MainActor in
                GlobalHotkey.shared.handleModifierOnlyEvent(event)
            }
            return event
        }

        if !InputAutomation.hasAccessibilityAccess {
            log.warning("Modifier-only shortcut is waiting for Accessibility access")
        }
        return globalModifierMonitor != nil && localModifierMonitor != nil
    }

    private func stopModifierOnlyMonitoring() {
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
        }
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
        }
        globalModifierMonitor = nil
        localModifierMonitor = nil
        modifierOnlyConfig = nil
        modifierOnlyIsDown = false
        modifierOnlyWasCombined = false
    }

    private func handleModifierOnlyEvent(_ event: NSEvent) {
        guard let config = modifierOnlyConfig,
              let eventFlag = HotkeyConfig.eventModifierFlag(for: config.keyCode)
        else { return }

        guard event.type == .flagsChanged else {
            if modifierOnlyIsDown {
                modifierOnlyWasCombined = true
            }
            return
        }

        let activeFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        guard UInt32(event.keyCode) == config.keyCode else {
            if modifierOnlyIsDown {
                modifierOnlyWasCombined = true
            }
            return
        }

        if activeFlags.contains(eventFlag) {
            modifierOnlyIsDown = true
            modifierOnlyWasCombined = !activeFlags.subtracting(eventFlag).isEmpty
            return
        }

        guard modifierOnlyIsDown else { return }
        let shouldFire = !modifierOnlyWasCombined && activeFlags.isEmpty
        modifierOnlyIsDown = false
        modifierOnlyWasCombined = false
        if shouldFire {
            log.info("Received modifier-only dictation hotkey")
            let handler = Self.onFire
            DispatchQueue.main.async { handler?() }
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
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr else { return parameterStatus }

                let handler: (@Sendable () -> Void)?
                switch hotKeyID.id {
                case 1: handler = GlobalHotkey.onFire
                case 2: handler = GlobalHotkey.onMeetingNotesFire
                default: return OSStatus(eventNotHandledErr)
                }
                log.info("Received global hotkey id=\(hotKeyID.id, privacy: .public)")
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
