#if os(iOS)
@preconcurrency import AVFoundation
import Combine
import CoreML
import FluidAudio
import Foundation
import OSLog
import UIKit

nonisolated private let log = Logger(
    subsystem: "com.tmoreton.yaprflow.ios",
    category: "Transcription"
)

enum TranscriptionError: LocalizedError {
    case microphoneDenied
    case modelsMissing

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access denied"
        case .modelsMissing: return "Speech model files are missing from the app bundle"
        }
    }
}

enum MobileCaptureMode: String, CaseIterable, Identifiable {
    case quick
    case meeting

    var id: Self { self }

    var displayName: String {
        switch self {
        case .quick: "Dictation"
        case .meeting: "Meeting"
        }
    }
}

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case finishing
    case copied
    case saved
    case error(String)
}

/// A lock-backed, bounded FIFO that can be written synchronously from the
/// realtime audio callback and drained by one MainActor task. Every packet is
/// tagged with its capture generation so a late callback can never leak into a
/// restarted session.
nonisolated final class AudioBufferFIFO: @unchecked Sendable {
    struct Packet {
        let generation: UInt
        let buffer: AVAudioPCMBuffer
    }

    enum EnqueueResult {
        case accepted
        case startPump
        case overflow
        case rejected
    }

    private struct Waiter {
        let generation: UInt
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let capacity: Int
    private var packets: [Packet] = []
    private var head = 0
    private var activeGeneration: UInt?
    private var accepting = false
    private var pumpScheduled = false
    private var waiters: [Waiter] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        packets.reserveCapacity(capacity)
    }

    func begin(generation: UInt) {
        lock.lock()
        let oldWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        packets.removeAll(keepingCapacity: true)
        head = 0
        activeGeneration = generation
        accepting = true
        pumpScheduled = false
        lock.unlock()
        oldWaiters.forEach { $0.continuation.resume() }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, generation: UInt) -> EnqueueResult {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, activeGeneration == generation else { return .rejected }

        guard pendingCountLocked < capacity else {
            // Stop accepting immediately. The controller reports the overload
            // and drains everything already accepted without growing memory.
            accepting = false
            return .overflow
        }

        packets.append(Packet(generation: generation, buffer: buffer))
        if !pumpScheduled {
            pumpScheduled = true
            return .startPump
        }
        return .accepted
    }

    /// Close admission after AudioCapture has removed the tap. Returns true
    /// only if a pump must be created to drain packets accepted before stop.
    func close(generation: UInt) -> Bool {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return false
        }
        accepting = false

        if pendingCountLocked > 0, !pumpScheduled {
            pumpScheduled = true
            lock.unlock()
            return true
        }

        let completed = pendingCountLocked == 0 && !pumpScheduled
        let completedWaiters = completed ? removeWaitersLocked(for: generation) : []
        lock.unlock()
        completedWaiters.forEach { $0.continuation.resume() }
        return false
    }

    func next(generation: UInt) -> Packet? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation, pendingCountLocked > 0 else { return nil }
        let packet = packets[head]
        head += 1
        if head >= 64, head * 2 >= packets.count {
            packets.removeFirst(head)
            head = 0
        }
        return packet
    }

    /// Called only by the single consumer after it observes an empty queue.
    /// An enqueue racing that observation either leaves data for this pump or
    /// schedules the next pump; no wake-up can be lost.
    func finishPump(generation: UInt) -> Bool {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return false
        }

        if pendingCountLocked > 0 {
            lock.unlock()
            return true
        }

        pumpScheduled = false
        let completedWaiters = accepting ? [] : removeWaitersLocked(for: generation)
        lock.unlock()
        completedWaiters.forEach { $0.continuation.resume() }
        return false
    }

    func waitUntilDrained(generation: UInt) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activeGeneration != generation || (pendingCountLocked == 0 && !pumpScheduled) {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(Waiter(generation: generation, continuation: continuation))
                lock.unlock()
            }
        }
    }

    func discard(generation: UInt) {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        accepting = false
        packets.removeAll(keepingCapacity: true)
        head = 0
        pumpScheduled = false
        activeGeneration = nil
        let completedWaiters = removeWaitersLocked(for: generation)
        lock.unlock()
        completedWaiters.forEach { $0.continuation.resume() }
    }

    private var pendingCountLocked: Int { packets.count - head }

    private func removeWaitersLocked(for generation: UInt) -> [Waiter] {
        let completed = waiters.filter { $0.generation == generation }
        waiters.removeAll { $0.generation == generation }
        return completed
    }
}

@MainActor
final class TranscriptionEngine: ObservableObject {
    static let shared = TranscriptionEngine()

    private struct RecognizerLoad {
        let id: UInt
        let task: Task<AsrManager, Error>
        var installAllowed: Bool
    }

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published private(set) var activeMode: MobileCaptureMode?

    /// Rolling history of recent normalized audio levels (0...1). Updated at
    /// roughly the audio buffer rate while recording, decays toward zero when
    /// idle. Size is fixed; SwiftUI renders this directly as a bar waveform.
    @Published var levels: [Float] = Array(repeating: 0, count: TranscriptionEngine.levelCount)
    static let levelCount = 80

    private let history = HistoryStore.shared
    private let meetingStore = MobileMeetingStore.shared
    private let capture: AudioCapture
    private let audioFIFO: AudioBufferFIFO
    private let audioConverter = StreamingAudioConverter()

    private var speechRecognizer: AsrManager?
    private var vadManager: VoiceActivityDetector?
    private var recognizerLoad: RecognizerLoad?
    private var vadLoadingTask: Task<VoiceActivityDetector?, Never>?
    private var nextRecognizerLoadID: UInt = 0

    // Per-session state
    private var sessionAudio = RollingSessionAudio()
    private var vadPending: [Float] = []
    private var vadState: VoiceActivityStreamState?
    private var currentSpeechStart: Int?
    private var currentSpeechFedThrough: Int?
    private var lastFinalizedAudioEnd = 0
    private var activeSegmentID: Int?
    private var activeSegmentHasLeadingOverlap = false
    private var nextSegmentID = 0
    private var confirmedText = ""
    private var volatileText = ""
    private var volatileSegmentID: Int?
    private var sessionGeneration: UInt = 0
    private var requestedMode: MobileCaptureMode = .quick
    private var sessionStartedAt: Date?
    private var recognitionFailure: Error?

    private var lifecycle: RecordingLifecyclePhase = .idle
    private var startRequested = false
    private var autoHideTask: Task<Void, Never>?
    private var modelUnloadTask: Task<Void, Never>?
    private var usesVoiceDetectorForCurrentSession = true
    private var releaseModelAfterSession = false

    private static let sampleRate = 16_000
    private static let hardSegmentSamples = 30 * sampleRate
    private static let shortRecordingFallbackSamples = hardSegmentSamples
    private static let forcedSegmentOverlapSamples = 3 * sampleRate / 2

    private let segmentationConfig = VoiceActivitySegmentationConfiguration(
        minSilenceDuration: 0.6,
        speechStartPadding: 0.35,
        speechEndPadding: 0.45
    )

    private var decayTimer: Timer?

    private init() {
        let fifo = AudioBufferFIFO(capacity: 128)
        self.audioFIFO = fifo

        let bufferHandler: AudioCapture.BufferHandler = { buffer, generation in
            switch fifo.enqueue(buffer, generation: generation) {
            case .accepted, .rejected:
                break
            case .startPump:
                Task { @MainActor in
                    await TranscriptionEngine.shared.pumpAudio(generation: generation)
                }
            case .overflow:
                Task { @MainActor in
                    await TranscriptionEngine.shared.handleAudioQueueOverflow(
                        generation: generation
                    )
                }
            }
        }
        let eventHandler: AudioCapture.EventHandler = { event in
            Task { @MainActor in
                await TranscriptionEngine.shared.handleCaptureEvent(event)
            }
        }
        self.capture = AudioCapture(
            bufferHandler: bufferHandler,
            eventHandler: eventHandler
        )
        // 30Hz decay tick. Cheap; only mutates levels when something changed.
        self.decayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isRecording { self.decayLevels() }
            }
        }
    }

    func toggle(mode: MobileCaptureMode = .quick) {
        Task { @MainActor in
            switch lifecycle {
            case .recording:
                startRequested = false
                await stop()
            case .starting:
                // Model construction is synchronous native work and cannot be
                // interrupted safely. Toggle the user's intent so the pending
                // start is abandoned when the shared cold-load task completes.
                startRequested.toggle()
                if startRequested {
                    authorizeRecognizerLoad()
                }
                liveTranscript = ""
                status = startRequested
                    ? .preparing("Loading speech model…")
                    : .idle
            case .stopping:
                // Finalization continues after capture stops. Preserve a new
                // tap as a queued restart; a second tap cancels that restart.
                startRequested.toggle()
                if startRequested { requestedMode = mode }
                log.info("Queued restart after finalization: \(self.startRequested, privacy: .public)")
            case .idle:
                requestedMode = mode
                activeMode = mode
                startRequested = true
                await start()
            }
        }
    }

    var isRecording: Bool {
        if case .recording = lifecycle { return true }
        return false
    }

    var isRecordingPending: Bool {
        if case .starting = lifecycle { return startRequested }
        return false
    }

    var isBusy: Bool {
        switch lifecycle {
        case .idle: false
        case .starting, .recording, .stopping: true
        }
    }

    var recordingStartedAt: Date? { sessionStartedAt }

    func resetPresentation() {
        guard lifecycle == .idle else { return }
        autoHideTask?.cancel()
        status = .idle
        liveTranscript = ""
        activeMode = nil
    }

    func preload() {
        Task { @MainActor in
            do {
                _ = try await ensureSpeechRecognizer(showStatus: true)
                _ = await ensureVoiceDetector(showStatus: true)
                if lifecycle == .idle {
                    status = .idle
                    scheduleModelUnload()
                }
            } catch is CancellationError {
                log.info("Preload was discarded before installation")
            } catch {
                log.error("Preload failed: \(error.localizedDescription)")
                if lifecycle == .idle {
                    status = .error(error.localizedDescription)
                    scheduleAutoHide(after: 2.5)
                }
            }
        }
    }

    private func start() async {
        guard lifecycle == .idle else { return }
        startRequested = true
        sessionGeneration &+= 1
        let generation = sessionGeneration
        lifecycle = .starting(generation)
        defer {
            if lifecycle == .starting(generation) {
                lifecycle = .idle
            }
            if lifecycle == .idle, releaseModelAfterSession {
                releaseModelAfterSession = false
                releaseSpeechModelIfIdle(reason: "deferred system pressure")
            }
        }

        autoHideTask?.cancel()
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        confirmedText = ""
        volatileText = ""
        volatileSegmentID = nil
        currentSpeechFedThrough = nil
        activeSegmentID = nil
        activeSegmentHasLeadingOverlap = false
        lastFinalizedAudioEnd = 0
        recognitionFailure = nil
        liveTranscript = ""
        audioConverter.reset()

        do {
            try await ensureMicPermission()
            guard startRequested, lifecycle == .starting(generation) else {
                log.info("Pending recording cancelled before model loading")
                status = .idle
                scheduleModelUnload()
                return
            }

            _ = try await ensureSpeechRecognizer(showStatus: true)
            let vad = await ensureVoiceDetector(showStatus: true)
            guard startRequested, lifecycle == .starting(generation) else {
                log.info("Pending recording cancelled after model loading")
                status = .idle
                scheduleModelUnload()
                return
            }

            sessionAudio.reset(keepingCapacity: true)
            vadPending.removeAll(keepingCapacity: true)
            if let vad {
                vadState = await vad.makeStreamState()
                usesVoiceDetectorForCurrentSession = true
            } else {
                vadState = nil
                usesVoiceDetectorForCurrentSession = false
                log.info("Starting without optional voice activity detection")
            }
            currentSpeechStart = nil
            currentSpeechFedThrough = nil

            guard startRequested, lifecycle == .starting(generation) else {
                log.info("Pending recording cancelled before microphone capture")
                status = .idle
                scheduleModelUnload()
                return
            }

            audioFIFO.begin(generation: generation)
            try capture.start(generation: generation)
            guard startRequested, lifecycle == .starting(generation) else {
                capture.stop()
                audioFIFO.discard(generation: generation)
                status = .idle
                scheduleModelUnload()
                return
            }
            lifecycle = .recording(generation)
            sessionStartedAt = Date()
            status = .listening
        } catch {
            capture.stop()
            audioFIFO.discard(generation: generation)
            let shouldReportError = startRequested
            startRequested = false
            guard shouldReportError else {
                log.info("Suppressed start error after the pending recording was cancelled")
                status = .idle
                scheduleModelUnload()
                return
            }
            log.error("Start failed: \(error.localizedDescription)")
            activeMode = nil
            sessionStartedAt = nil
            status = .error(error.localizedDescription)
            scheduleAutoHide(after: 2.5)
            scheduleModelUnload()
        }
    }

    private func stop(reason: String? = nil) async {
        guard case .recording(let generation) = lifecycle else { return }
        lifecycle = .stopping(generation)
        startRequested = false

        capture.stop()
        status = .finishing

        // AudioCapture.stop() is a callback barrier. Close admission only after
        // it returns, drain every accepted FIFO packet, and then finalize ASR.
        if audioFIFO.close(generation: generation) {
            await pumpAudio(generation: generation)
        }
        await audioFIFO.waitUntilDrained(generation: generation)

        do {
            let converterTail = try audioConverter.finish()
            if !converterTail.isEmpty {
                await feed(converterTail, generation: generation)
            }
        } catch {
            log.error("Could not drain final converted microphone audio: \(error.localizedDescription)")
        }

        let sessionEnd = sessionAudio.endIndex
        if currentSpeechStart != nil {
            await feedCurrentSpeech(upTo: sessionEnd)
            lastFinalizedAudioEnd = max(
                lastFinalizedAudioEnd,
                currentSpeechFedThrough ?? sessionEnd
            )
            await finishCurrentSpeech()
        } else if usesVoiceDetectorForCurrentSession, !sessionAudio.isEmpty {
            // Preserve a very short final utterance without retaining or
            // replaying the full recording.
            let fallbackStart = max(lastFinalizedAudioEnd, sessionAudio.startIndex)
            if fallbackStart < sessionEnd {
                log.info("Transcribing the bounded final audio tail")
                await beginCurrentSpeech(at: fallbackStart)
                await feedCurrentSpeech(upTo: sessionEnd)
                lastFinalizedAudioEnd = max(
                    lastFinalizedAudioEnd,
                    currentSpeechFedThrough ?? sessionEnd
                )
                await finishCurrentSpeech()
            }
        }

        let finalText = TranscriptSegments.capitalizingFirstLetter(
            in: confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let completionReason = reason ?? recognitionFailure.map {
            "Speech recognition failed: \($0.localizedDescription)"
        }

        // The recognizer has finished consuming this session. Release raw
        // microphone samples immediately; only the resulting text persists.
        let capturedSeconds = Double(sessionEnd) / Double(Self.sampleRate)
        let completedMode = activeMode ?? requestedMode
        let endedAt = Date()
        let startedAt = sessionStartedAt
            ?? endedAt.addingTimeInterval(-capturedSeconds)
        log.info("Finalized \(capturedSeconds, format: .fixed(precision: 2), privacy: .public) seconds of captured audio")

        sessionAudio.reset(keepingCapacity: false)
        vadPending.removeAll(keepingCapacity: false)
        vadState = nil
        currentSpeechStart = nil
        currentSpeechFedThrough = nil
        lastFinalizedAudioEnd = 0
        activeSegmentID = nil
        activeSegmentHasLeadingOverlap = false
        volatileSegmentID = nil
        liveTranscript = finalText
        audioFIFO.discard(generation: generation)
        lifecycle = .idle
        activeMode = nil
        sessionStartedAt = nil

        switch completedMode {
        case .quick:
            if !finalText.isEmpty {
                UIPasteboard.general.string = finalText
                history.add(finalText)
                if let reason = completionReason {
                    status = .error("Partial text copied — \(reason)")
                    scheduleAutoHide(after: 2.5)
                } else {
                    status = .copied
                    scheduleAutoHide(after: 1.5)
                }
            } else {
                if let reason = completionReason {
                    status = .error(reason)
                    scheduleAutoHide(after: 2.5)
                } else {
                    status = .idle
                    scheduleAutoHide(after: 1.0)
                }
            }

        case .meeting:
            if !finalText.isEmpty || meetingStore.hasDraftContent {
                do {
                    _ = try meetingStore.saveCapture(
                        transcript: finalText,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        duration: capturedSeconds
                    )
                    if let reason = completionReason {
                        status = .error("Partial meeting saved — \(reason)")
                        scheduleAutoHide(after: 3.0)
                    } else {
                        status = .saved
                        scheduleAutoHide(after: 2.0)
                    }
                } catch {
                    status = .error("Meeting could not be saved — \(error.localizedDescription)")
                    scheduleAutoHide(after: 3.0)
                }
            } else if let reason = completionReason {
                status = .error(reason)
                scheduleAutoHide(after: 2.5)
            } else {
                status = .idle
                scheduleAutoHide(after: 1.0)
            }
        }

        if releaseModelAfterSession {
            releaseModelAfterSession = false
            releaseSpeechModelIfIdle(reason: "deferred system pressure")
        } else {
            scheduleModelUnload()
        }

        if startRequested {
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    private func pumpAudio(generation: UInt) async {
        while true {
            while let packet = audioFIFO.next(generation: generation) {
                guard packet.generation == generation,
                      isProcessingSession(generation)
                else { continue }

                do {
                    let samples = try audioConverter.resampleBuffer(packet.buffer)
                    if !samples.isEmpty {
                        await feed(samples, generation: generation)
                    }
                } catch {
                    log.error("Resample failed: \(error.localizedDescription)")
                }
            }

            if !audioFIFO.finishPump(generation: generation) {
                return
            }
        }
    }

    private func isProcessingSession(_ generation: UInt) -> Bool {
        lifecycle == .recording(generation) || lifecycle == .stopping(generation)
    }

    private func handleAudioQueueOverflow(generation: UInt) async {
        guard lifecycle == .recording(generation) else { return }
        log.error("The bounded audio FIFO filled; stopping before memory can grow")
        await stop(reason: "Audio processing could not keep up")
    }

    private func handleCaptureEvent(_ event: AudioCaptureEvent) async {
        switch event {
        case .interruptionBegan:
            log.info("Audio capture was interrupted")
            if isRecording {
                await stop(reason: "Recording was interrupted")
            }
        case .interruptionEnded(let shouldResume):
            log.info("Audio interruption ended; system resume hint: \(shouldResume, privacy: .public)")
        case .routeChanged(let rawReason):
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            log.info("Audio route changed with reason \(rawReason, privacy: .public)")
            if reason == .newDeviceAvailable
                || reason == .oldDeviceUnavailable
                || reason == .routeConfigurationChange
                || reason == .noSuitableRouteForCategory
            {
                if isRecording {
                    await stop(reason: "Microphone route changed")
                }
            }
        case .mediaServicesReset:
            log.info("iOS audio services were reset")
            if isRecording {
                await stop(reason: "Audio services restarted")
            }
        case .failure(let message):
            log.error("Audio capture failed: \(message, privacy: .public)")
            if isRecording {
                await stop(reason: message)
            }
        }
    }

    func applicationDidEnterBackground() {
        handleSystemPressure(reason: "app entered background")
    }

    func applicationDidReceiveMemoryWarning() {
        handleSystemPressure(reason: "memory warning")
    }

    private func handleSystemPressure(reason: String) {
        switch lifecycle {
        case .idle:
            releaseSpeechModelIfIdle(reason: reason)
        case .starting:
            // A speculative preload/start must not install hundreds of MB
            // after the system asks us to shed memory.
            startRequested = false
            discardRecognizerLoad(reason: reason)
            releaseModelAfterSession = true
        case .recording, .stopping:
            // The active decoder owns the current transcript. Release it as
            // soon as that session has completed its real drain/finalization.
            releaseModelAfterSession = true
        }
    }

    private func feed(_ samples: [Float], generation: UInt) async {
        guard isProcessingSession(generation) else { return }

        let appendStart = sessionAudio.endIndex
        sessionAudio.append(samples)
        pushLevel(from: samples)

        if !usesVoiceDetectorForCurrentSession {
            await continueWithoutVoiceDetector(from: appendStart)
            return
        }

        guard let vad = vadManager, var currentVadState = vadState else { return }
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
            guard isProcessingSession(generation) else { return }
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
                await finishCurrentSpeech()
                trimRetainedSessionAudio()
            }
        }

        // Once VAD has opened a speech interval, advance the same stateful
        // recognizer with newly arrived samples. This produces real online
        // hypotheses rather than re-transcribing the whole interval.
        await feedCurrentSpeech(upTo: sessionAudio.endIndex)
        trimRetainedSessionAudio()
    }

    /// Compute RMS over the buffer, normalize to ~[0,1] with a perceptual
    /// curve, and append to the rolling level history. Cheap enough to run on
    /// every buffer.
    private func pushLevel(from samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        // Map ~-50dBFS..0dBFS to 0..1 with a soft floor.
        let db = 20 * log10(max(rms, 1e-5))
        let normalized = max(0, min(1, (db + 50) / 50))
        // Slight perceptual boost so quiet speech still moves the bars.
        let curved = powf(normalized, 0.7)
        var next = levels
        next.removeFirst()
        next.append(curved)
        levels = next
    }

    /// Decay the level history toward zero. Called from a timer when not
    /// recording, so the waveform settles to a flat line instead of freezing
    /// on the last loud frame.
    private func decayLevels() {
        var next = levels
        var changed = false
        for i in next.indices {
            let v = next[i] * 0.85
            if v > 0.001 {
                next[i] = v
                changed = true
            } else if next[i] != 0 {
                next[i] = 0
                changed = true
            }
        }
        if changed { levels = next }
    }

    private func beginCurrentSpeech(
        at requestedStart: Int,
        initiallyThrough requestedInitialEnd: Int? = nil,
        hasLeadingOverlap: Bool = false
    ) async {
        // A second start should not normally arrive without an end. If VAD is
        // reset mid-session, close the old decoder cleanly before replacing it.
        if currentSpeechStart != nil {
            await feedCurrentSpeech(upTo: sessionAudio.endIndex)
            lastFinalizedAudioEnd = max(
                lastFinalizedAudioEnd,
                currentSpeechFedThrough ?? sessionAudio.endIndex
            )
            await finishCurrentSpeech()
        }

        let start = max(
            sessionAudio.startIndex,
            min(requestedStart, sessionAudio.endIndex)
        )
        let initialEnd = max(
            start,
            min(requestedInitialEnd ?? sessionAudio.endIndex, sessionAudio.endIndex)
        )
        currentSpeechStart = start
        currentSpeechFedThrough = initialEnd
        nextSegmentID += 1
        let segmentID = nextSegmentID
        activeSegmentID = segmentID
        activeSegmentHasLeadingOverlap = hasLeadingOverlap

        // Parakeet transcribes the complete bounded segment when it closes.
        // Keep only the indexes here so the raw samples can remain in the
        // rolling buffer until finalization.
        applyPartial("", for: segmentID)
    }

    private func feedCurrentSpeech(upTo requestedEnd: Int) async {
        let targetEnd = max(
            sessionAudio.startIndex,
            min(requestedEnd, sessionAudio.endIndex)
        )

        while let segmentStart = currentSpeechStart,
              let fedThrough = currentSpeechFedThrough,
              let segmentID = activeSegmentID
        {
            let hardEnd = segmentStart + Self.hardSegmentSamples
            let feedEnd = min(targetEnd, hardEnd)

            if feedEnd > fedThrough {
                currentSpeechFedThrough = feedEnd
                applyPartial("", for: segmentID)
            }

            guard feedEnd >= hardEnd else { break }

            lastFinalizedAudioEnd = max(lastFinalizedAudioEnd, hardEnd)
            await finishCurrentSpeech()

            let continuationStart = max(
                sessionAudio.startIndex,
                hardEnd - Self.forcedSegmentOverlapSamples
            )
            await beginCurrentSpeech(
                at: continuationStart,
                initiallyThrough: hardEnd,
                hasLeadingOverlap: true
            )
            log.info("Forced a Parakeet segment boundary at 30 seconds")
        }
    }

    private func finishCurrentSpeech() async {
        guard let segmentID = activeSegmentID else {
            currentSpeechStart = nil
            currentSpeechFedThrough = nil
            return
        }

        let hasLeadingOverlap = activeSegmentHasLeadingOverlap
        let start = currentSpeechStart ?? sessionAudio.startIndex
        let finalizedThrough = currentSpeechFedThrough ?? currentSpeechStart ?? 0
        if let recognizer = speechRecognizer {
            let samples = sessionAudio.samples(from: start, to: finalizedThrough)
            if !samples.isEmpty {
                do {
                    let prepared = OfflineRecognitionAudio.paddedToMinimumDuration(samples)
                    let result = try await transcribeWithOneRetry(
                        recognizer: recognizer,
                        samples: prepared
                    )
                    commitFinal(
                        result.text,
                        for: segmentID,
                        deduplicatingLeadingOverlap: hasLeadingOverlap
                    )
                } catch {
                    recognitionFailure = error
                    log.error("Parakeet transcription failed: \(error.localizedDescription)")
                }
            }
        }

        lastFinalizedAudioEnd = max(lastFinalizedAudioEnd, finalizedThrough)
        currentSpeechStart = nil
        currentSpeechFedThrough = nil
        activeSegmentID = nil
        activeSegmentHasLeadingOverlap = false
    }

    private func transcribeWithOneRetry(
        recognizer: AsrManager,
        samples: [Float]
    ) async throws -> ASRResult {
        do {
            return try await recognizer.transcribe(samples, source: .microphone)
        } catch {
            log.error("Parakeet segment failed; retrying once: \(error.localizedDescription)")
            try? await recognizer.resetDecoderState(for: .microphone)
            return try await recognizer.transcribe(samples, source: .microphone)
        }
    }

    private func continueWithoutVoiceDetector(from requestedStart: Int) async {
        if currentSpeechStart == nil {
            await beginCurrentSpeech(at: requestedStart)
        }
        await feedCurrentSpeech(upTo: sessionAudio.endIndex)
        trimRetainedSessionAudio()
    }

    private func trimRetainedSessionAudio() {
        let retainFrom: Int
        if let segmentStart = currentSpeechStart {
            // Offline Parakeet recognition needs the entire active segment.
            retainFrom = max(sessionAudio.startIndex, segmentStart)
        } else {
            retainFrom = max(
                sessionAudio.startIndex,
                sessionAudio.endIndex - Self.shortRecordingFallbackSamples
            )
        }
        sessionAudio.discard(before: retainFrom)
    }

    private func applyPartial(_ rawText: String, for segmentID: Int) {
        guard isRecording, activeSegmentID == segmentID else { return }
        volatileText = Self.cleanTranscript(rawText)
        volatileSegmentID = segmentID
        liveTranscript = displayText()
    }

    private func commitFinal(
        _ rawText: String,
        for segmentID: Int,
        deduplicatingLeadingOverlap: Bool
    ) {
        let cleaned = Self.cleanTranscript(rawText)
        if !cleaned.isEmpty {
            confirmedText = TranscriptSegments.appending(
                cleaned,
                to: confirmedText,
                deduplicatingLeadingOverlap: deduplicatingLeadingOverlap
            )
        }
        // Do not erase a newer segment's partial if it has already decoded.
        if volatileSegmentID == segmentID {
            volatileText = ""
            volatileSegmentID = nil
        }
        liveTranscript = displayText()
    }

    private static func cleanTranscript(_ raw: String) -> String {
        TranscriptPolishing.polish(raw, normalizingEnglishAllCaps: true)
    }

    private func displayText() -> String {
        TranscriptSegments.capitalizingFirstLetter(
            in: TranscriptSegments.combining(
                confirmed: confirmedText,
                volatile: volatileText
            )
        )
    }

    private func ensureMicPermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .undetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
            if granted { return }
            throw TranscriptionError.microphoneDenied
        case .denied:
            throw TranscriptionError.microphoneDenied
        @unknown default:
            throw TranscriptionError.microphoneDenied
        }
    }

    private func ensureSpeechRecognizer(showStatus: Bool) async throws -> AsrManager {
        if let speechRecognizer { return speechRecognizer }
        if showStatus {
            status = .preparing("Loading speech model…")
        }

        let load: RecognizerLoad
        if var existing = recognizerLoad {
            // A foreground request may adopt a still-running native load that
            // was invalidated in the background. Never start a second large
            // decoder while the first task is still unwinding.
            existing.installAllowed = true
            recognizerLoad = existing
            load = existing
        } else {
            guard let modelDirectory = Self.bundledASRDir() else {
                throw TranscriptionError.modelsMissing
            }

            nextRecognizerLoadID &+= 1
            let id = nextRecognizerLoadID
            log.info("Loading Parakeet ASR from \(modelDirectory.path, privacy: .public)")
            let task = Task(priority: .userInitiated) {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndGPU
                let models = try await AsrModels.load(
                    from: modelDirectory,
                    configuration: configuration,
                    version: .v3
                )
                let recognizer = AsrManager(config: .default)
                try await recognizer.loadModels(models)
                try await Self.warmUp(recognizer: recognizer)
                return recognizer
            }
            load = RecognizerLoad(id: id, task: task, installAllowed: true)
            recognizerLoad = load
        }

        let loaded = try await load.task.value
        if let speechRecognizer {
            // Another waiter on the same preload already installed it.
            return speechRecognizer
        }
        guard
            let currentLoad = recognizerLoad,
            currentLoad.id == load.id,
            currentLoad.installAllowed
        else {
            // A background transition or memory warning invalidated this load
            // while native model construction was still completing.
            if recognizerLoad?.id == load.id {
                recognizerLoad = nil
            }
            throw CancellationError()
        }

        recognizerLoad = nil
        speechRecognizer = loaded
        return loaded
    }

    /// VAD is a quality optimization, not a prerequisite for transcription.
    /// Load the compiled bundle directly with Core ML; this path never performs
    /// a runtime download or network request.
    private func ensureVoiceDetector(showStatus: Bool) async -> VoiceActivityDetector? {
        if let vadManager { return vadManager }
        if showStatus {
            status = .preparing("Loading voice detector…")
        }

        let task: Task<VoiceActivityDetector?, Never>
        if let existing = vadLoadingTask {
            task = existing
        } else {
            guard let modelURL = Self.bundledVADModelURL() else {
                log.error("Bundled VAD is missing; continuing without VAD")
                return nil
            }

            task = Task.detached(priority: .userInitiated) {
                do {
                    let modelConfiguration = MLModelConfiguration()
                    modelConfiguration.computeUnits = .cpuAndNeuralEngine
                    let model = try MLModel(
                        contentsOf: modelURL,
                        configuration: modelConfiguration
                    )
                    let vad = VoiceActivityDetector(model: model)
                    await Self.warmUp(vad: vad)
                    return vad
                } catch {
                    log.error("Bundled VAD failed to load: \(error.localizedDescription)")
                    return nil
                }
            }
            vadLoadingTask = task
        }

        let loaded = await task.value
        if let vadManager { return vadManager }
        vadLoadingTask = nil
        vadManager = loaded
        return loaded
    }

    private static func bundledASRDir() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
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
            else { return nil }
        }
        return dir
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

    private static func warmUp(recognizer: AsrManager) async throws {
        let silence = OfflineRecognitionAudio.paddedToMinimumDuration(
            [Float](repeating: 0, count: 16_000)
        )
        _ = try await recognizer.transcribe(silence, source: .microphone)
    }

    private static func warmUp(vad: VoiceActivityDetector) async {
        do {
            let chunk = [Float](
                repeating: 0.0,
                count: VoiceActivityDetector.chunkSize
            )
            let state = await vad.makeStreamState()
            _ = try await vad.processStreamingChunk(
                chunk,
                state: state,
                configuration: .init()
            )
        } catch {
            log.info("VAD warmup skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch { return }
            if lifecycle == .idle {
                status = .idle
                liveTranscript = ""
            }
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
            self?.releaseSpeechModelIfIdle(reason: "5 minutes idle")
        }
    }

    private func discardRecognizerLoad(reason: String) {
        guard var load = recognizerLoad else { return }
        load.installAllowed = false
        recognizerLoad = load
        load.task.cancel()
        log.info("Discarded pending Parakeet load after \(reason, privacy: .public)")
    }

    private func authorizeRecognizerLoad() {
        guard var load = recognizerLoad else { return }
        load.installAllowed = true
        recognizerLoad = load
    }

    private func releaseSpeechModelIfIdle(reason: String) {
        guard lifecycle == .idle else { return }

        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        discardRecognizerLoad(reason: reason)
        let releasedLoadedModel = speechRecognizer != nil
        speechRecognizer = nil
        if releasedLoadedModel {
            log.info("Released the Parakeet model after \(reason, privacy: .public)")
        }
    }
}
#endif
