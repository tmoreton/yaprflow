@preconcurrency import AVFoundation

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is connected. Connect or select one in System Settings → Sound → Input."
        case .invalidInputFormat:
            return "The selected microphone is unavailable. Choose another input in System Settings → Sound → Input."
        }
    }
}

nonisolated final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private let callbackGroup = DispatchGroup()
    private var running = false
    private var acceptingCallbacks = false
    private var activeGeneration: UInt?
    private var configurationObserver: NSObjectProtocol?
    private let prefersVoiceProcessing: Bool
    private let bufferHandler: @Sendable (UInt, AVAudioPCMBuffer) -> Void
    private let configurationChangeHandler: @Sendable (UInt) -> Void

    init(
        prefersVoiceProcessing: Bool = false,
        bufferHandler: @escaping @Sendable (UInt, AVAudioPCMBuffer) -> Void,
        configurationChangeHandler: @escaping @Sendable (UInt) -> Void
    ) {
        self.prefersVoiceProcessing = prefersVoiceProcessing
        self.bufferHandler = bufferHandler
        self.configurationChangeHandler = configurationChangeHandler
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func validateInputAvailable() throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioCaptureError.noInputDevice
        }
    }

    func start(sessionGeneration: UInt) throws {
        stateLock.lock()
        let isAlreadyRunning = running || acceptingCallbacks
        stateLock.unlock()
        guard !isAlreadyRunning else { return }
        try validateInputAvailable()

        let input = engine.inputNode
        if prefersVoiceProcessing {
            // Apple's voice-processing input includes acoustic echo
            // cancellation, but its default "typical voice chat" configuration
            // also ducks other apps' audio. Meeting capture observes an
            // existing call rather than rendering one, so keep echo
            // cancellation while minimizing that unwanted volume reduction.
            // Advanced ducking is inappropriate here because it can make the
            // remote participant nearly inaudible whenever local speech is
            // detected.
            do {
                if !input.isVoiceProcessingEnabled {
                    try input.setVoiceProcessingEnabled(true)
                }
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                NSLog("Yaprflow: meeting microphone voice processing unavailable: %@", error.localizedDescription)
            }
        }
        do {
            try startInputTap(input, sessionGeneration: sessionGeneration)
        } catch {
            guard prefersVoiceProcessing, input.isVoiceProcessingEnabled else { throw error }
            // Some input devices advertise voice processing but cannot start
            // a recording graph with it. Restore ordinary capture rather
            // than sacrificing the meeting transcript.
            try input.setVoiceProcessingEnabled(false)
            try startInputTap(input, sessionGeneration: sessionGeneration)
        }
    }

    private func startInputTap(_ input: AVAudioInputNode, sessionGeneration: UInt) throws {
        let format = input.inputFormat(forBus: 0)
        guard Self.supportsCaptureFormat(format) else {
            throw AudioCaptureError.invalidInputFormat
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.stateLock.lock()
            guard self.acceptingCallbacks else {
                self.stateLock.unlock()
                return
            }
            self.callbackGroup.enter()
            self.stateLock.unlock()
            defer { self.callbackGroup.leave() }
            guard let copy = AudioCapture.copy(buffer: buffer) else { return }
            self.bufferHandler(sessionGeneration, copy)
        }

        stateLock.lock()
        acceptingCallbacks = true
        activeGeneration = sessionGeneration
        stateLock.unlock()

        do {
            engine.prepare()
            try engine.start()
            stateLock.lock()
            running = true
            stateLock.unlock()
        } catch {
            // A failed start leaves the installed tap behind unless it is
            // explicitly removed. That stale tap makes the next Start fail.
            stateLock.lock()
            acceptingCallbacks = false
            activeGeneration = nil
            stateLock.unlock()
            engine.stop()
            input.removeTap(onBus: 0)
            callbackGroup.wait()
            throw error
        }
    }

    var isVoiceProcessingActive: Bool {
        engine.inputNode.isVoiceProcessingEnabled
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        acceptingCallbacks = false
        activeGeneration = nil
        stateLock.unlock()
        guard wasRunning else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        // Once the tap is removed, wait for any callback already executing to
        // finish handing its copied buffer to the session FIFO. This makes the
        // caller's subsequent FIFO finish a real end-of-input barrier.
        callbackGroup.wait()
    }

    private func handleConfigurationChange() {
        stateLock.lock()
        let generation = running ? activeGeneration : nil
        stateLock.unlock()
        guard let generation else { return }
        configurationChangeHandler(generation)
    }

    static func supportsCaptureFormat(_ format: AVAudioFormat) -> Bool {
        let supportsSampleStorage = format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatInt16
        return format.sampleRate > 0
            && format.channelCount > 0
            && supportsSampleStorage
            && (!format.isInterleaved || format.channelCount == 1)
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)
        else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        let channelBufferCount = buffer.format.isInterleaved ? 1 : channels
        let samplesPerBuffer = frames * (buffer.format.isInterleaved ? channels : 1)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let src = buffer.floatChannelData, let dst = copy.floatChannelData else {
                return nil
            }
            for ch in 0..<channelBufferCount {
                dst[ch].update(from: src[ch], count: samplesPerBuffer)
            }
        case .pcmFormatInt16:
            guard let src = buffer.int16ChannelData, let dst = copy.int16ChannelData else {
                return nil
            }
            for ch in 0..<channelBufferCount {
                dst[ch].update(from: src[ch], count: samplesPerBuffer)
            }
        default:
            return nil
        }
        return copy
    }
}
