@preconcurrency import AVFoundation
import AppKit
import CoreML
import FluidAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Transcription")

enum TranscriptionError: LocalizedError {
    case microphoneDenied
    case microphonePermissionTimedOut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access denied"
        case .microphonePermissionTimedOut:
            return "Microphone access did not respond. Reopen Yaprflow after enabling it in System Settings → Privacy & Security → Microphone."
        }
    }
}

nonisolated final class MicrophonePermissionContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?

    init(_ continuation: CheckedContinuation<Bool?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

struct RecordingSmokeTestResult {
    let succeeded: Bool
    let message: String
}

nonisolated struct CapturedAudioPacket: @unchecked Sendable {
    let generation: UInt
    let buffer: AVAudioPCMBuffer
}

/// A generation-scoped FIFO between AVAudioEngine's realtime callback and the
/// single async inference worker. The bounded stream prevents a slow decoder
/// from turning an hour-long recording into an unbounded task/buffer backlog.
nonisolated final class BoundedAudioIngress: @unchecked Sendable {
    private struct Session {
        let generation: UInt
        let continuation: AsyncStream<CapturedAudioPacket>.Continuation
        var droppedAudio = false
    }

    private let lock = NSLock()
    private let capacity: Int
    private var session: Session?

    init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func beginSession(generation: UInt) -> AsyncStream<CapturedAudioPacket> {
        let pair = AsyncStream<CapturedAudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )

        lock.lock()
        let previousContinuation = session?.continuation
        session = Session(
            generation: generation,
            continuation: pair.continuation
        )
        lock.unlock()

        previousContinuation?.finish()
        return pair.stream
    }

    func enqueue(generation: UInt, buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard var current = session, current.generation == generation else {
            lock.unlock()
            return
        }

        let result = current.continuation.yield(
            CapturedAudioPacket(generation: generation, buffer: buffer)
        )
        if case .dropped = result {
            current.droppedAudio = true
            session = current
        }
        lock.unlock()
    }

    /// Finish the current generation and return whether bounded buffering ever
    /// had to drop a newly captured packet.
    @discardableResult
    func finishSession(generation: UInt) -> Bool {
        lock.lock()
        guard let current = session, current.generation == generation else {
            lock.unlock()
            return false
        }
        session = nil
        lock.unlock()

        current.continuation.finish()
        return current.droppedAudio
    }
}

@MainActor
final class TranscriptionController {
    static let shared = TranscriptionController()

    private enum StopReason {
        case userInitiated
        case audioConfigurationChanged
    }

    private let state = AppState.shared
    private let audioIngress: BoundedAudioIngress
    private let capture: AudioCapture
    private let audioConverter = StreamingAudioConverter()
    private let memoryPressureSource: DispatchSourceMemoryPressure

    // Models stay warm between nearby recordings, then unload while idle.
    // Parakeet's Core ML weights are shared by dictation and meetings.
    private var speechRecognizer: AsrManager?
    private var vadManager: VoiceActivityDetector?
    private var speechRecognizerLoadingTask: Task<AsrManager, Error>?
    private var voiceDetectorLoadingTask: Task<Void, Never>?
    private var modelUnloadTask: Task<Void, Never>?

    // Per-session state
    private var sessionAudio = RollingSessionAudio()
    private var vadPending: [Float] = []
    private var vadState: VoiceActivityStreamState?
    private var currentSpeechStart: Int?
    private var currentSpeechFedThrough: Int?
    private var lastFinalizedAudioEnd = 0
    private var confirmedText = ""
    private var vocabularyReplacementCount = 0
    private var sessionSourceApplication: String?
    private var audioWorkerTask: Task<Void, Never>?
    private var transcriptProcessor: TranscriptProcessor?
    private var sessionGeneration: UInt = 0
    private var recognizerStreamIsOpen = false
    private var recognizerStreamHasLeadingOverlap = false
    private var usesVoiceDetectorForCurrentSession = false
    private var recognitionFailure: Error?

    private var lifecycle: RecordingLifecyclePhase = .idle
    private var isActive: Bool {
        if case .recording = lifecycle { return true }
        return false
    }
    private var isStarting: Bool {
        if case .starting = lifecycle { return true }
        return false
    }
    private var isStopping: Bool {
        if case .stopping = lifecycle { return true }
        return false
    }
    private var startRequested = false
    private var suppressTranscriptSideEffectsForSmokeTest = false
    private var autoHideTask: Task<Void, Never>?

    private static let sampleRate = 16_000
    private static let hardSegmentSamples = 30 * sampleRate
    private static let shortRecordingFallbackSamples = hardSegmentSamples
    private static let forcedSegmentOverlapSamples = 3 * sampleRate / 2

    // Natural pauses are preferred boundaries. The controller independently
    // enforces the 30-second segment ceiling used by the speech recognizer.
    private let segmentationConfig = VoiceActivitySegmentationConfiguration(
        minSilenceDuration: 0.6,
        speechStartPadding: 0.35,
        speechEndPadding: 0.45
    )

    private init() {
        let audioIngress = BoundedAudioIngress()
        self.audioIngress = audioIngress
        let bufferHandler: @Sendable (UInt, AVAudioPCMBuffer) -> Void = { generation, buffer in
            audioIngress.enqueue(generation: generation, buffer: buffer)
        }
        let configurationChangeHandler: @Sendable (UInt) -> Void = { generation in
            Task { @MainActor in
                await TranscriptionController.shared.handleAudioConfigurationChange(
                    generation: generation
                )
            }
        }
        self.capture = AudioCapture(
            bufferHandler: bufferHandler,
            configurationChangeHandler: configurationChangeHandler
        )

        let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        self.memoryPressureSource = memoryPressureSource
        memoryPressureSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.releaseModelsIfIdle(reason: "system memory pressure")
            }
        }
        memoryPressureSource.resume()
    }

    func toggle() {
        if MeetingSessionController.shared.isRecording {
            state.status = .error("Stop Meeting Notes before starting dictation")
            return
        }
        log.info("Recording toggle requested (active: \(self.isActive, privacy: .public), starting: \(self.isStarting, privacy: .public), stopping: \(self.isStopping, privacy: .public))")
        Task { @MainActor in
            if isActive {
                startRequested = false
                await stop()
            } else if isStarting {
                // Model construction is synchronous native work and cannot be
                // interrupted safely. Toggle the user's intent instead, then
                // either abandon the pending start or resume it when the shared
                // cold-load task completes.
                startRequested.toggle()
                state.audioLevel = 0
                state.status = startRequested
                    ? .preparing("Preparing voice model…")
                    : .idle
            } else if isStopping {
                // Finalization continues off the capture path after Stop. Keep
                // a new hotkey/menu request instead of silently dropping it;
                // pressing the shortcut again cancels the queued restart.
                startRequested.toggle()
                log.info("Queued restart after finalization: \(self.startRequested, privacy: .public)")
            } else {
                startRequested = true
                await start()
            }
        }
    }

    /// Prepare the small VAD model independently from the speech model. This
    /// starts at app launch, stays off the recording-critical path, and keeps
    /// the detector warm because its memory footprint is tiny.
    func prepareVoiceDetector() {
        guard vadManager == nil, voiceDetectorLoadingTask == nil else { return }

        voiceDetectorLoadingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.voiceDetectorLoadingTask = nil }

            do {
                self.vadManager = try await Self.loadBundledVoiceDetector()
                log.info("Voice detector prepared in the background")
            } catch {
                // Recording remains usable without VAD through the same
                // bounded streaming recognizer path.
                log.error("Voice detector preparation failed; using continuous streaming: \(error.localizedDescription)")
            }
        }
    }

    /// Warm Parakeet at launch so the first recording does not have to wait for
    /// Core ML to initialize its graphs.
    func prepareSpeechRecognizer() {
        guard speechRecognizer == nil, speechRecognizerLoadingTask == nil else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.ensureLoaded(showLoadingStatus: false)
                log.info("Speech recognizer prepared in the background")
                self.scheduleModelUnload()
            } catch {
                // A later recording attempt retries and surfaces the error to
                // the user. Background preparation must not open the overlay.
                log.error("Speech recognizer background preparation failed: \(error.localizedDescription)")
            }
        }
    }

    func runRecordingSmokeTest(
        startAction: (@MainActor () -> Void)? = nil,
        stopAction: (@MainActor () -> Void)? = nil
    ) async -> RecordingSmokeTestResult {
        guard !isActive, !isStarting, !isStopping else {
            return RecordingSmokeTestResult(
                succeeded: false,
                message: "A recording was already active."
            )
        }
        suppressTranscriptSideEffectsForSmokeTest = true
        defer { suppressTranscriptSideEffectsForSmokeTest = false }

        if let startAction {
            startAction()
            await waitForRecordingToStart()
        } else {
            await start()
        }
        guard isActive, state.status == .listening else {
            return RecordingSmokeTestResult(
                succeeded: false,
                message: "Could not enter the listening state: \(smokeTestStatusDescription)"
            )
        }

        do {
            try await Task.sleep(for: .seconds(1))
            let phrase = "Violet rockets travel beyond the quiet forest. This sentence tests dictation capture."
            guard try await Self.playRecordingSmokeTestPhrase(phrase) else {
                await stop()
                return RecordingSmokeTestResult(
                    succeeded: false,
                    message: "The Dictation test phrase could not be played."
                )
            }
            try await Task.sleep(for: .seconds(4))
        } catch {
            await stop()
            return RecordingSmokeTestResult(succeeded: false, message: "The recording test was interrupted.")
        }

        if let stopAction {
            stopAction()
            await waitForRecordingToStop()
        } else {
            await stop()
        }
        let markerWords = Set([
            "violet", "rockets", "quiet", "forest",
            "sentence", "tests", "quick", "dictation", "capture",
        ])
        let recognizedWords = Set(
            confirmedText.lowercased().split { !$0.isLetter }.map(String.init)
        )
        let markerCount = recognizedWords.intersection(markerWords).count
        return RecordingSmokeTestResult(
            succeeded: !isActive && markerCount >= 4,
            message: "Dictation captured \(markerCount) test markers and stopped successfully."
        )
    }

    private static func playRecordingSmokeTestPhrase(_ phrase: String) async throws -> Bool {
        let speaker = Process()
        speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speaker.arguments = ["-r", "150", phrase]
        try speaker.run()
        while speaker.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        return speaker.terminationStatus == 0
    }

    private func waitForRecordingToStart() async {
        for _ in 0..<1_200 {
            if isActive || isErrorStatus { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForRecordingToStop() async {
        for _ in 0..<1_200 {
            if !isActive, !isStarting, !isStopping { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private var isErrorStatus: Bool {
        if case .error = state.status { return true }
        return false
    }

    private var smokeTestStatusDescription: String {
        switch state.status {
        case .idle: return "idle"
        case let .preparing(message): return message
        case .listening: return "listening"
        case .copied: return "copied"
        case let .error(message): return message
        }
    }

    private func start() async {
        guard !isActive, !isStarting, !isStopping else { return }
        log.info("Starting recording pipeline")
        startRequested = true
        sessionGeneration &+= 1
        let generation = sessionGeneration
        lifecycle = .starting(generation)
        defer {
            if lifecycle == .starting(generation) {
                lifecycle = .idle
            }
        }

        autoHideTask?.cancel()
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        confirmedText = ""
        vocabularyReplacementCount = 0
        transcriptProcessor = state.makeTranscriptProcessor()
        sessionSourceApplication = Self.frontmostApplicationName()
        audioWorkerTask = nil
        audioConverter.reset()
        sessionAudio.reset(keepingCapacity: true)
        lastFinalizedAudioEnd = 0
        recognizerStreamHasLeadingOverlap = false
        recognitionFailure = nil
        state.audioLevel = 0
        // Present honest startup progress immediately. Do not claim to be
        // listening until the recognizer is ready and microphone capture has
        // actually started.
        _ = NotchOverlayWindowController.shared
        state.status = .preparing("Preparing voice model…")

        do {
            try await ensureMicPermission()
            guard startRequested else {
                log.info("Pending recording cancelled before model loading")
                transcriptProcessor = nil
                scheduleModelUnload()
                return
            }
            try capture.validateInputAvailable()
            prepareVoiceDetector()
            _ = try await ensureLoaded()
            guard startRequested else {
                log.info("Pending recording cancelled after model loading")
                transcriptProcessor = nil
                scheduleModelUnload()
                return
            }

            vadPending.removeAll(keepingCapacity: true)
            usesVoiceDetectorForCurrentSession = vadManager != nil
            if let vad = vadManager, usesVoiceDetectorForCurrentSession {
                vadState = await vad.makeStreamState()
            } else {
                vadState = nil
                log.info("Voice detector is not ready; recording will use bounded offline segments")
            }
            currentSpeechStart = nil
            currentSpeechFedThrough = nil

            // With VAD, open a segment only when speech begins and backfill the
            // detector's padded onset. Without VAD, continuously form bounded
            // offline segments from the first frame.
            recognizerStreamIsOpen = false
            if !usesVoiceDetectorForCurrentSession {
                recognizerStreamIsOpen = true
                currentSpeechStart = 0
                currentSpeechFedThrough = 0
            }

            guard startRequested else {
                recognizerStreamIsOpen = false
                log.info("Pending recording cancelled before microphone capture")
                transcriptProcessor = nil
                scheduleModelUnload()
                return
            }

            let stream = audioIngress.beginSession(generation: generation)
            audioWorkerTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await packet in stream {
                    guard packet.generation == generation,
                          self.sessionGeneration == generation
                    else { continue }
                    await self.consumeCapturedBuffer(packet.buffer)
                }
            }
            state.status = .preparing("Starting microphone…")
            try capture.start(sessionGeneration: generation)
            lifecycle = .recording(generation)
            state.status = .listening
            Telemetry.shared.track(.dictationStarted)
            log.info("Microphone capture started (session: \(generation, privacy: .public))")
        } catch {
            audioIngress.finishSession(generation: generation)
            await audioWorkerTask?.value
            audioWorkerTask = nil
            let shouldReportError = startRequested
            startRequested = false
            transcriptProcessor = nil
            recognizerStreamIsOpen = false
            guard shouldReportError else {
                log.info("Suppressed start error after the pending recording was cancelled")
                state.status = .idle
                scheduleModelUnload()
                return
            }
            log.error("Start failed: \(error.localizedDescription)")
            state.status = .error(error.localizedDescription)
            Telemetry.shared.track(.dictationFailed(error is TranscriptionError ? .microphone : .startup))
            scheduleAutoHide(after: 2.5)
            scheduleModelUnload()
        }
    }

    private func stop(reason: StopReason = .userInitiated) async {
        guard case .recording(let generation) = lifecycle else { return }
        lifecycle = .stopping(generation)
        defer {
            lifecycle = .idle
            if startRequested {
                Task { @MainActor [weak self] in
                    await self?.start()
                }
            }
        }
        startRequested = false
        autoHideTask?.cancel()
        capture.stop()
        state.audioLevel = 0
        state.status = .idle

        // AudioCapture.stop() drains callbacks already executing. Finish the
        // matching generation only after that barrier, then let the one FIFO
        // worker consume every accepted packet before closing the recognizer.
        let droppedCapturedAudio = audioIngress.finishSession(
            generation: generation
        )
        await audioWorkerTask?.value
        audioWorkerTask = nil

        do {
            let converterTail = try audioConverter.finish()
            if !converterTail.isEmpty {
                await feed(converterTail)
            }
        } catch {
            recognitionFailure = recognitionFailure ?? error
            log.error("Could not drain final converted microphone audio: \(error.localizedDescription)")
        }

        let sessionEnd = sessionAudio.endIndex
        if currentSpeechStart != nil {
            await feedCurrentSpeech(upTo: sessionEnd)
            lastFinalizedAudioEnd = max(
                lastFinalizedAudioEnd,
                currentSpeechFedThrough ?? sessionEnd
            )
            await finishRecognizerStream()
            currentSpeechStart = nil
            currentSpeechFedThrough = nil
        } else if usesVoiceDetectorForCurrentSession, !sessionAudio.isEmpty {
            // VAD may not emit an event for a very short final utterance. Feed
            // only the retained tail rather than ever replaying an hour-long
            // session at Stop.
            let fallbackStart = max(lastFinalizedAudioEnd, sessionAudio.startIndex)
            if fallbackStart < sessionEnd {
                log.info("Transcribing the bounded final audio tail")
                await beginCurrentSpeech(at: fallbackStart)
                await feedCurrentSpeech(upTo: sessionEnd)
                lastFinalizedAudioEnd = max(
                    lastFinalizedAudioEnd,
                    currentSpeechFedThrough ?? sessionEnd
                )
                await finishRecognizerStream()
                currentSpeechStart = nil
                currentSpeechFedThrough = nil
            }
        }
        let finalText = TranscriptSegments.capitalizingFirstLetter(
            in: confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let capturedSeconds = Double(sessionEnd) / Double(Self.sampleRate)
        var telemetryFailure: TelemetryFailure?
        log.info("Finalized \(capturedSeconds, format: .fixed(precision: 2), privacy: .public) seconds of bounded audio")

        sessionAudio.reset(keepingCapacity: false)
        vadPending.removeAll(keepingCapacity: false)
        vadState = nil
        currentSpeechStart = nil
        currentSpeechFedThrough = nil
        lastFinalizedAudioEnd = 0
        recognizerStreamHasLeadingOverlap = false

        if suppressTranscriptSideEffectsForSmokeTest {
            if finalText.isEmpty {
                state.status = .error("No speech detected")
                telemetryFailure = .noSpeech
                log.info("The Dictation smoke test did not recognize its microphone signal")
            } else {
                state.status = .copied
                log.info("The Dictation smoke test recognized its microphone signal")
            }
        } else if !finalText.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            if pb.setString(finalText, forType: .string) {
                log.info("Transcript copied to the clipboard")
                do {
                    try state.recordTranscript(
                        finalText,
                        mode: transcriptProcessor?.mode,
                        sourceApplication: sessionSourceApplication,
                        vocabularyReplacementCount: vocabularyReplacementCount
                    )
                } catch {
                    state.status = .error("Copied, but couldn’t save transcript history")
                    telemetryFailure = .archive
                    scheduleAutoHide(after: 2.4)
                    log.error("Could not archive the copied transcript: \(error.localizedDescription)")
                }

                if case .error = state.status {
                    // Keep the more specific archive failure visible.
                } else if let recognitionFailure {
                    state.status = .error("Copied partial text; transcription failed: \(recognitionFailure.localizedDescription)")
                    telemetryFailure = .startup
                    scheduleAutoHide(after: 3.5)
                } else if droppedCapturedAudio {
                    state.status = .error("Audio processing fell behind; copied text may be incomplete")
                    telemetryFailure = .audioOverrun
                    scheduleAutoHide(after: 2.4)
                    log.error("The bounded capture FIFO overflowed during this recording")
                } else {
                    switch reason {
                    case .userInitiated:
                        // Only claim success after NSPasteboard accepted the
                        // finalized transcript.
                        state.status = .copied
                        scheduleAutoHide(after: 1.2)
                    case .audioConfigurationChanged:
                        state.status = .error("Microphone changed; captured text was copied")
                        telemetryFailure = .microphoneChanged
                        scheduleAutoHide(after: 2.4)
                    }
                }
            } else {
                state.status = .error("Couldn’t copy the transcript")
                telemetryFailure = .clipboard
                scheduleAutoHide(after: 2.4)
                log.error("The system pasteboard rejected the transcript")
            }
        } else {
            // Do not silently dismiss the overlay. This makes a genuinely
            // empty recording distinguishable from a missing confirmation.
            if let recognitionFailure {
                state.status = .error("Transcription failed: \(recognitionFailure.localizedDescription)")
                telemetryFailure = .startup
            } else {
                switch reason {
                case .userInitiated:
                    state.status = .error("No speech detected")
                    telemetryFailure = .noSpeech
                case .audioConfigurationChanged:
                    state.status = .error("Microphone changed; recording stopped")
                    telemetryFailure = .microphoneChanged
                }
            }
            scheduleAutoHide(after: 2.4)
            log.info("No speech was detected in the completed recording")
        }
        if let telemetryFailure {
            Telemetry.shared.track(.dictationFailed(telemetryFailure))
        } else {
            Telemetry.shared.track(.dictationCompleted(durationSeconds: capturedSeconds))
        }
        usesVoiceDetectorForCurrentSession = false
        transcriptProcessor = nil
        scheduleModelUnload()
    }

    private func consumeCapturedBuffer(_ buffer: AVAudioPCMBuffer) async {
        let samples: [Float]
        do {
            samples = try audioConverter.resampleBuffer(buffer)
        } catch {
            log.error("Resample failed: \(error.localizedDescription)")
            return
        }
        guard !samples.isEmpty else { return }
        await feed(samples)
    }

    private func handleAudioConfigurationChange(generation: UInt) async {
        guard generation == sessionGeneration, isActive, !isStopping else { return }
        log.error("Audio engine configuration changed; stopping the active recording safely")
        await stop(reason: .audioConfigurationChanged)
    }

    private func feed(_ samples: [Float]) async {
        let measuredLevel = Double(AudioLevelMeter.normalizedLevel(for: samples))
        state.audioLevel = state.audioLevel * 0.35 + measuredLevel * 0.65

        let appendStart = sessionAudio.endIndex
        sessionAudio.append(samples)

        if !usesVoiceDetectorForCurrentSession {
            await continueWithoutVoiceDetector(from: appendStart)
            return
        }

        guard let vad = vadManager,
              var currentVadState = vadState
        else { return }
        vadPending.append(contentsOf: samples)

        while vadPending.count >= VoiceActivityDetector.chunkSize {
            let chunk = Array(vadPending.prefix(VoiceActivityDetector.chunkSize))
            vadPending.removeFirst(VoiceActivityDetector.chunkSize)

            let result: VoiceActivityStreamResult
            do {
                result = try await vad.processStreamingChunk(
                    chunk,
                    state: currentVadState,
                    configuration: segmentationConfig
                )
            } catch {
                log.error("VAD failed: \(error.localizedDescription)")
                usesVoiceDetectorForCurrentSession = false
                vadState = nil
                vadPending.removeAll(keepingCapacity: false)
                await continueWithoutVoiceDetector(
                    from: max(lastFinalizedAudioEnd, sessionAudio.startIndex)
                )
                return
            }
            currentVadState = result.state
            vadState = currentVadState

            guard let event = result.event else { continue }
            switch event.kind {
            case .speechStart:
                await beginCurrentSpeech(at: event.sampleIndex)
            case .speechEnd:
                guard currentSpeechStart != nil else { continue }
                let clampedEnd = max(
                    sessionAudio.startIndex,
                    min(event.sampleIndex, sessionAudio.endIndex)
                )
                await feedCurrentSpeech(upTo: clampedEnd)
                lastFinalizedAudioEnd = max(
                    lastFinalizedAudioEnd,
                    currentSpeechFedThrough ?? clampedEnd
                )
                await finishRecognizerStream()
                currentSpeechStart = nil
                currentSpeechFedThrough = nil
                trimRetainedSessionAudio()
            }
        }

        await feedCurrentSpeech(upTo: sessionAudio.endIndex)
        trimRetainedSessionAudio()
    }

    private func beginCurrentSpeech(at requestedStart: Int) async {
        if currentSpeechStart != nil {
            await feedCurrentSpeech(upTo: sessionAudio.endIndex)
            lastFinalizedAudioEnd = max(
                lastFinalizedAudioEnd,
                currentSpeechFedThrough ?? sessionAudio.endIndex
            )
            await finishRecognizerStream()
            currentSpeechStart = nil
            currentSpeechFedThrough = nil
        }

        let start = max(
            sessionAudio.startIndex,
            min(requestedStart, sessionAudio.endIndex)
        )
        currentSpeechStart = start
        currentSpeechFedThrough = start
        await beginRecognizerStream()
    }

    private func feedCurrentSpeech(upTo requestedEnd: Int) async {
        let targetEnd = max(
            sessionAudio.startIndex,
            min(requestedEnd, sessionAudio.endIndex)
        )

        while recognizerStreamIsOpen,
              let segmentStart = currentSpeechStart,
              let fedThrough = currentSpeechFedThrough
        {
            let hardEnd = segmentStart + Self.hardSegmentSamples
            let feedEnd = min(targetEnd, hardEnd)

            if feedEnd > fedThrough {
                currentSpeechFedThrough = feedEnd
            }

            guard feedEnd >= hardEnd else { break }

            // The VAD owns pause boundaries; offline ASR duration is enforced
            // here. Reopen with a short overlap so a word crossing an
            // artificial boundary is not lost.
            lastFinalizedAudioEnd = max(lastFinalizedAudioEnd, hardEnd)
            await finishRecognizerStream()
            currentSpeechStart = nil
            currentSpeechFedThrough = nil

            let continuationStart = max(
                sessionAudio.startIndex,
                hardEnd - Self.forcedSegmentOverlapSamples
            )
            currentSpeechStart = continuationStart
            currentSpeechFedThrough = continuationStart
            await beginRecognizerStream(hasLeadingOverlap: true)
            log.info("Forced an offline ASR segment boundary at 30 seconds")
        }
    }

    private func continueWithoutVoiceDetector(from requestedStart: Int) async {
        if !recognizerStreamIsOpen {
            let start = max(
                sessionAudio.startIndex,
                min(requestedStart, sessionAudio.endIndex)
            )
            currentSpeechStart = start
            currentSpeechFedThrough = start
            await beginRecognizerStream()
        } else if currentSpeechStart == nil {
            let start = max(
                sessionAudio.startIndex,
                min(requestedStart, sessionAudio.endIndex)
            )
            currentSpeechStart = start
            currentSpeechFedThrough = start
        }

        await feedCurrentSpeech(upTo: sessionAudio.endIndex)
        trimRetainedSessionAudio()
    }

    private func beginRecognizerStream(hasLeadingOverlap: Bool = false) async {
        guard !recognizerStreamIsOpen,
              speechRecognizer != nil
        else { return }
        recognizerStreamIsOpen = true
        recognizerStreamHasLeadingOverlap = hasLeadingOverlap
    }

    private func finishRecognizerStream() async {
        guard recognizerStreamIsOpen,
              let recognizer = speechRecognizer
        else { return }

        let start = currentSpeechStart ?? sessionAudio.startIndex
        let end = currentSpeechFedThrough ?? start
        let samples = sessionAudio.samples(from: start, to: end)

        // Close the flag before awaiting so a stop that resumes on the main
        // actor cannot finalize this segment a second time.
        recognizerStreamIsOpen = false
        let shouldDeduplicate = recognizerStreamHasLeadingOverlap
        recognizerStreamHasLeadingOverlap = false
        guard !samples.isEmpty else { return }
        do {
            let preparedSamples = OfflineRecognitionAudio.paddedToMinimumDuration(samples)
            let result = try await transcribeWithOneRetry(
                recognizer: recognizer,
                samples: preparedSamples,
                source: .microphone
            )
            appendConfirmedText(
                result.text,
                deduplicatingLeadingOverlap: shouldDeduplicate
            )
        } catch {
            recognitionFailure = error
            log.error("Parakeet transcription failed: \(error.localizedDescription)")
        }
    }

    private func transcribeWithOneRetry(
        recognizer: AsrManager,
        samples: [Float],
        source: AudioSource
    ) async throws -> ASRResult {
        do {
            return try await recognizer.transcribe(samples, source: source)
        } catch {
            log.error("Parakeet section failed; retrying once: \(error.localizedDescription)")
            try? await recognizer.resetDecoderState(for: source)
            return try await recognizer.transcribe(samples, source: source)
        }
    }

    private func trimRetainedSessionAudio() {
        let retainFrom: Int
        if let segmentStart = currentSpeechStart {
            // Offline recognition needs the complete active segment. Do not
            // apply the former streaming trim to audio not yet decoded.
            retainFrom = max(sessionAudio.startIndex, segmentStart)
        } else {
            retainFrom = max(
                sessionAudio.startIndex,
                sessionAudio.endIndex - Self.shortRecordingFallbackSamples
            )
        }
        sessionAudio.discard(before: retainFrom)
    }

    private func appendConfirmedText(
        _ rawText: String,
        deduplicatingLeadingOverlap: Bool
    ) {
        let processed = processRecognizerText(rawText)
        if !processed.text.isEmpty {
            confirmedText = TranscriptSegments.appending(
                processed.text,
                to: confirmedText,
                deduplicatingLeadingOverlap: deduplicatingLeadingOverlap
            )
            vocabularyReplacementCount += processed.vocabularyReplacementCount
        }
    }

    private func processRecognizerText(_ rawText: String) -> TranscriptProcessingResult {
        let processor: TranscriptProcessor
        if let transcriptProcessor {
            processor = transcriptProcessor
        } else {
            let created = state.makeTranscriptProcessor()
            transcriptProcessor = created
            processor = created
        }
        return processor.process(Self.normalizedRecognizerText(rawText))
    }

    /// Parakeet normally emits punctuation and casing. Keep those intact while
    /// retaining compatibility with all-uppercase text from older exports.
    private static func normalizedRecognizerText(_ rawText: String) -> String {
        let collapsed = rawText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }

        var text = collapsed
        if text.contains(where: { $0.isLetter }), text == text.uppercased() {
            text = text.lowercased()
        }
        let range = NSRange(text.startIndex..., in: text)
        text = standalonePronounRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "I"
        )
        return text
    }

    private static let standalonePronounRegex = try! NSRegularExpression(
        pattern: #"\bi\b"#
    )

    private static func frontmostApplicationName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func ensureMicPermission() async throws {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("Microphone authorization status: \(Self.authorizationStatusDescription(authorizationStatus), privacy: .public)")

        switch authorizationStatus {
        case .authorized:
            return
        case .notDetermined:
            log.info("Requesting microphone access")
            guard let granted = await requestMicrophoneAccess(timeout: 15) else {
                log.error("Microphone access request timed out")
                throw TranscriptionError.microphonePermissionTimedOut
            }
            log.info("Microphone access request completed (granted: \(granted, privacy: .public))")
            if granted { return }
            throw TranscriptionError.microphoneDenied
        case .denied, .restricted:
            throw TranscriptionError.microphoneDenied
        @unknown default:
            throw TranscriptionError.microphoneDenied
        }
    }

    private func requestMicrophoneAccess(timeout: TimeInterval) async -> Bool? {
        await withCheckedContinuation { continuation in
            let oneShot = MicrophonePermissionContinuation(continuation)

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                oneShot.resume(returning: granted)
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                oneShot.resume(returning: nil)
            }
        }
    }

    private static func authorizationStatusDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private func ensureLoaded(
        showLoadingStatus: Bool = true
    ) async throws -> AsrManager {
        if let recognizer = speechRecognizer { return recognizer }
        if showLoadingStatus {
            state.status = .preparing("Loading voice model…")
        }

        let task: Task<AsrManager, Error>
        if let existing = speechRecognizerLoadingTask {
            task = existing
        } else {
            let modelDir = try Self.bundledModelDirectory()
            log.info("Loading ASR model from \(modelDir.path, privacy: .public)")
            task = Task(priority: .userInitiated) {
                let configuration = MLModelConfiguration()
                // This is the known-stable configuration for the v3 Core ML
                // export and avoids Neural Engine compilation/cache churn.
                configuration.computeUnits = .cpuAndGPU
                let models = try await AsrModels.load(
                    from: modelDir,
                    configuration: configuration,
                    version: .v3
                )
                let recognizer = AsrManager(config: .default)
                try await recognizer.loadModels(models)
                return recognizer
            }
            speechRecognizerLoadingTask = task
        }

        do {
            let recognizer = try await task.value
            speechRecognizerLoadingTask = nil
            self.speechRecognizer = recognizer
            return recognizer
        } catch {
            speechRecognizerLoadingTask = nil
            throw error
        }
    }

    private static func bundledModelDirectory() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Yaprflow's bundled speech model is missing. Please reinstall the app.",
            ])
        }

        let dir = resources.appendingPathComponent(
            BundledModelInventory.parakeetSpeechDirectory,
            isDirectory: true
        )
        let fm = FileManager.default
        for file in BundledModelInventory.parakeetSpeechFiles {
            let url = dir.appendingPathComponent(file.name)
            guard
                fm.fileExists(atPath: url.path),
                let attributes = try? fm.attributesOfItem(atPath: url.path),
                let size = attributes[.size] as? NSNumber,
                size.int64Value == file.byteCount
            else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey: "Yaprflow's bundled speech model is incomplete. Please reinstall the app.",
                ])
            }
        }
        return dir
    }

    /// Meetings share the already-loaded Parakeet models with dictation. The
    /// manager is an actor and maintains independent microphone/system decoder
    /// state, so two sources cannot corrupt one another.
    func speechRecognizerForMeeting() async throws -> AsrManager {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        return try await ensureLoaded(showLoadingStatus: false)
    }

    func voiceDetectorForMeeting() async -> VoiceActivityDetector? {
        prepareVoiceDetector()
        await voiceDetectorLoadingTask?.value
        return vadManager
    }

    func meetingRecognitionDidEnd() {
        scheduleModelUnload()
    }

    private static func bundledVADModelURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let modelPath = resources
            .appendingPathComponent(
                BundledModelInventory.voiceDetectorDirectory,
                isDirectory: true
            )
            .appendingPathComponent(
                BundledModelInventory.voiceDetectorModel,
                isDirectory: true
            )
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return nil }
        return modelPath
    }

    /// Load the bundled VAD directly. The release always contains this model,
    /// so voice detection never performs a runtime download or network check.
    private static func loadBundledVoiceDetector() async throws -> VoiceActivityDetector {
        guard let modelURL = bundledVADModelURL() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: "\(BundledModelInventory.voiceDetectorDirectory)/\(BundledModelInventory.voiceDetectorModel)",
                NSLocalizedDescriptionKey: "The bundled voice detector is missing.",
            ])
        }

        return try await Task.detached(priority: .utility) {
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: modelURL, configuration: modelConfiguration)
            return VoiceActivityDetector(model: model)
        }.value
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            state.status = .idle
            state.audioLevel = 0
        }
    }

    private func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
            self?.releaseModelsIfIdle(reason: "5 minutes idle")
        }
    }

    private func releaseModelsIfIdle(reason: String) {
        guard !isActive,
              !isStarting,
              !isStopping,
              speechRecognizerLoadingTask == nil,
              audioWorkerTask == nil,
              !recognizerStreamIsOpen
        else {
            return
        }
        guard speechRecognizer != nil else { return }

        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        speechRecognizer = nil
        vadState = nil
        sessionAudio.reset(keepingCapacity: false)
        vadPending.removeAll(keepingCapacity: false)
        log.info("Released transcription models after \(reason, privacy: .public)")
    }
}
