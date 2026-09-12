#if os(iOS)
@preconcurrency import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow.ios", category: "AudioCapture")

enum AudioCaptureEvent: Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: UInt)
    case mediaServicesReset
    case failure(String)
}

enum AudioCaptureError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "No usable microphone input is available"
        }
    }
}

/// AVAudioEngine capture with synchronous delivery into the bounded ingress
/// queue. `stop()` removes the tap and waits for any callback already in flight,
/// which gives the transcription engine a real end-of-session barrier.
nonisolated final class AudioCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, UInt) -> Void
    typealias EventHandler = @Sendable (AudioCaptureEvent) -> Void

    private var engine = AVAudioEngine()
    private var running = false
    private var tapInstalled = false
    private let bufferHandler: BufferHandler
    private let eventHandler: EventHandler
    private let callbackCondition = NSCondition()
    private var acceptsCallbacks = false
    private var callbacksInFlight = 0
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        bufferHandler: @escaping BufferHandler,
        eventHandler: @escaping EventHandler
    ) {
        self.bufferHandler = bufferHandler
        self.eventHandler = eventHandler
        installNotificationObservers()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func start(generation: UInt) throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setActive(true, options: [])

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard Self.isUsable(format) else {
                throw AudioCaptureError.invalidInputFormat
            }

            callbackCondition.lock()
            acceptsCallbacks = true
            callbackCondition.unlock()

            input.installTap(onBus: 0, bufferSize: 4096, format: format) {
                [weak self] buffer, _ in
                guard let self, self.beginCallback() else { return }
                defer { self.endCallback() }

                guard let copy = Self.copy(buffer: buffer) else {
                    self.eventHandler(.failure("The microphone returned an unsupported audio format"))
                    return
                }
                self.bufferHandler(copy, generation)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            running = true
        } catch {
            cleanup(deactivateSession: true)
            throw error
        }
    }

    func stop() {
        cleanup(deactivateSession: true)
    }

    private func cleanup(deactivateSession: Bool) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if running || engine.isRunning {
            engine.stop()
        }
        running = false

        // No new tap callbacks can begin after the tap has been removed and
        // the engine stopped. Include every callback that already began before
        // closing the session's FIFO in TranscriptionEngine.
        callbackCondition.lock()
        acceptsCallbacks = false
        while callbacksInFlight > 0 {
            callbackCondition.wait()
        }
        callbackCondition.unlock()

        engine.reset()
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }

    private func beginCallback() -> Bool {
        callbackCondition.lock()
        defer { callbackCondition.unlock() }
        guard acceptsCallbacks else { return false }
        callbacksInFlight += 1
        return true
    }

    private func endCallback() {
        callbackCondition.lock()
        callbacksInFlight -= 1
        if callbacksInFlight == 0 {
            callbackCondition.broadcast()
        }
        callbackCondition.unlock()
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }

            switch type {
            case .began:
                self.eventHandler(.interruptionBegan)
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                self.eventHandler(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })

        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            else { return }

            self.eventHandler(.routeChanged(reason: reason.rawValue))
        })

        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cleanup(deactivateSession: false)
            self.engine = AVAudioEngine()
            self.eventHandler(.mediaServicesReset)
        })
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        guard
            format.sampleRate.isFinite,
            format.sampleRate > 0,
            format.channelCount > 0,
            format.channelCount <= 8,
            !format.isInterleaved
        else { return false }

        return format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatInt16
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            buffer.frameLength > 0,
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            )
        else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
            return copy
        }
        return nil
    }
}
#endif
