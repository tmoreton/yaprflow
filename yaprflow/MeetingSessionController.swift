@preconcurrency import AVFoundation
import AppKit
import Combine
import FluidAudio
import Foundation
import ScreenCaptureKit

enum MeetingSessionPhase: Equatable {
    case idle
    case preparing(String)
    case recording
    case paused
    case finalizing(String)
    case complete
    case failed(String)

    var isCapturing: Bool {
        self == .recording || self == .paused
    }
}

#if DEBUG
struct MeetingAudioSeparationSmokeTestResult {
    let succeeded: Bool
    let message: String
}
#endif

@MainActor
private final class MeetingRecognitionPipeline {
    private static let sampleRate = 16_000
    private static let maximumSegmentSamples = 25 * sampleRate
    private static let forcedSegmentOverlapSamples = 3 * sampleRate / 2
    private static let fallbackTailSamples = 30 * sampleRate

    let speaker: MeetingSpeaker
    private let recognizer: AsrManager
    private let voiceDetector: VoiceActivityDetector?
    private let transcriptProcessor: TranscriptProcessor
    private let echoDetector: MeetingPlaybackEchoDetector
    private let converter = StreamingAudioConverter()
    private var sessionAudio = RollingSessionAudio()
    private var vadPending: [Float] = []
    private var vadState: VoiceActivityStreamState?
    private var usesVoiceDetector = false
    private var currentSpeechStart: Int?
    private var currentSpeechFedThrough: Int?
    private var lastFinalizedAudioEnd = 0
    private var recognizerSegmentIsOpen = false
    private var recognizerSegmentHasLeadingOverlap = false
    private var confirmedText = ""
    private(set) var recentlyHadAudio = false

    private let segmentationConfig = VoiceActivitySegmentationConfiguration(
        minSilenceDuration: 0.6,
        speechStartPadding: 0.35,
        speechEndPadding: 0.45
    )

    init(
        speaker: MeetingSpeaker,
        recognizer: AsrManager,
        voiceDetector: VoiceActivityDetector?,
        transcriptProcessor: TranscriptProcessor,
        echoDetector: MeetingPlaybackEchoDetector
    ) {
        self.speaker = speaker
        self.recognizer = recognizer
        self.voiceDetector = voiceDetector
        self.transcriptProcessor = transcriptProcessor
        self.echoDetector = echoDetector
    }

    func start() async {
        converter.reset()
        sessionAudio.reset(keepingCapacity: true)
        vadPending.removeAll(keepingCapacity: true)
        usesVoiceDetector = voiceDetector != nil
        vadState = await voiceDetector?.makeStreamState()
        currentSpeechStart = nil
        currentSpeechFedThrough = nil
        lastFinalizedAudioEnd = 0
        recognizerSegmentIsOpen = false
        recognizerSegmentHasLeadingOverlap = false
        confirmedText = ""
        recentlyHadAudio = false

        if !usesVoiceDetector {
            recognizerSegmentIsOpen = true
            currentSpeechStart = 0
            currentSpeechFedThrough = 0
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) async throws -> [MeetingTranscriptSegment] {
        let samples = try converter.resampleBuffer(buffer)
        guard !samples.isEmpty else { return [] }
        return try await consume(samples: samples)
    }

    func finish() async throws -> [MeetingTranscriptSegment] {
        var completed: [MeetingTranscriptSegment] = []
        let converterTail = try converter.finish()
        if !converterTail.isEmpty {
            completed.append(contentsOf: try await consume(samples: converterTail))
        }

        let sessionEnd = sessionAudio.endIndex
        if currentSpeechStart != nil {
            completed.append(contentsOf: try await feedCurrentSpeech(upTo: sessionEnd))
            lastFinalizedAudioEnd = max(
                lastFinalizedAudioEnd,
                currentSpeechFedThrough ?? sessionEnd
            )
            if let segment = try await finishRecognizerSegment() {
                completed.append(segment)
            }
            currentSpeechStart = nil
            currentSpeechFedThrough = nil
        } else if usesVoiceDetector, !sessionAudio.isEmpty {
            // The VAD may never open for a very brief or quiet final utterance.
            // Keep this fallback bounded, but always give Parakeet the retained
            // tail rather than silently dropping it.
            let fallbackStart = max(lastFinalizedAudioEnd, sessionAudio.startIndex)
            if fallbackStart < sessionEnd {
                beginRecognizerSegment(at: fallbackStart)
                completed.append(contentsOf: try await feedCurrentSpeech(upTo: sessionEnd))
                if let segment = try await finishRecognizerSegment() {
                    completed.append(segment)
                }
                currentSpeechStart = nil
                currentSpeechFedThrough = nil
            }
        }

        sessionAudio.reset(keepingCapacity: false)
        vadPending.removeAll(keepingCapacity: false)
        vadState = nil
        return completed
    }

    private func consume(samples: [Float]) async throws -> [MeetingTranscriptSegment] {
        var completed: [MeetingTranscriptSegment] = []
        if speaker == .them {
            echoDetector.appendSystemSamples(samples)
        }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1 * $1) }
            / Double(samples.count)
        recentlyHadAudio = meanSquare > 0.000_025
        let appendStart = sessionAudio.endIndex
        sessionAudio.append(samples)

        guard usesVoiceDetector, let voiceDetector, var currentVadState = vadState else {
            completed.append(contentsOf: try await continueWithoutVoiceDetector(from: appendStart))
            return completed
        }
        vadPending.append(contentsOf: samples)

        while vadPending.count >= VoiceActivityDetector.chunkSize {
            let chunk = Array(vadPending.prefix(VoiceActivityDetector.chunkSize))
            vadPending.removeFirst(VoiceActivityDetector.chunkSize)

            let result: VoiceActivityStreamResult
            do {
                result = try await voiceDetector.processStreamingChunk(
                    chunk,
                    state: currentVadState,
                    configuration: segmentationConfig
                )
            } catch {
                usesVoiceDetector = false
                vadState = nil
                vadPending.removeAll(keepingCapacity: false)
                completed.append(contentsOf: try await continueWithoutVoiceDetector(
                    from: max(lastFinalizedAudioEnd, sessionAudio.startIndex)
                ))
                return completed
            }
            currentVadState = result.state
            vadState = currentVadState

            guard let event = result.event else { continue }
            switch event.kind {
            case .speechStart:
                if currentSpeechStart != nil {
                    completed.append(contentsOf: try await feedCurrentSpeech(
                        upTo: sessionAudio.endIndex
                    ))
                    if let segment = try await finishRecognizerSegment() {
                        completed.append(segment)
                    }
                }
                beginRecognizerSegment(at: event.sampleIndex)
            case .speechEnd:
                guard currentSpeechStart != nil else { continue }
                let end = max(
                    sessionAudio.startIndex,
                    min(event.sampleIndex, sessionAudio.endIndex)
                )
                completed.append(contentsOf: try await feedCurrentSpeech(upTo: end))
                lastFinalizedAudioEnd = max(
                    lastFinalizedAudioEnd,
                    currentSpeechFedThrough ?? end
                )
                if let segment = try await finishRecognizerSegment() {
                    completed.append(segment)
                }
                currentSpeechStart = nil
                currentSpeechFedThrough = nil
                trimRetainedAudio()
            }
        }

        completed.append(contentsOf: try await feedCurrentSpeech(upTo: sessionAudio.endIndex))
        trimRetainedAudio()
        return completed
    }

    private func beginRecognizerSegment(at requestedStart: Int, hasLeadingOverlap: Bool = false) {
        let start = max(sessionAudio.startIndex, min(requestedStart, sessionAudio.endIndex))
        currentSpeechStart = start
        currentSpeechFedThrough = start
        recognizerSegmentIsOpen = true
        recognizerSegmentHasLeadingOverlap = hasLeadingOverlap
    }

    private func feedCurrentSpeech(upTo requestedEnd: Int) async throws -> [MeetingTranscriptSegment] {
        var completed: [MeetingTranscriptSegment] = []
        let targetEnd = max(sessionAudio.startIndex, min(requestedEnd, sessionAudio.endIndex))

        while recognizerSegmentIsOpen,
              let segmentStart = currentSpeechStart,
              let fedThrough = currentSpeechFedThrough {
            let hardEnd = segmentStart + Self.maximumSegmentSamples
            let feedEnd = min(targetEnd, hardEnd)
            if feedEnd > fedThrough {
                currentSpeechFedThrough = feedEnd
            }
            guard feedEnd >= hardEnd else { break }

            lastFinalizedAudioEnd = max(lastFinalizedAudioEnd, hardEnd)
            if let segment = try await finishRecognizerSegment() {
                completed.append(segment)
            }
            let continuationStart = max(
                sessionAudio.startIndex,
                hardEnd - Self.forcedSegmentOverlapSamples
            )
            beginRecognizerSegment(at: continuationStart, hasLeadingOverlap: true)
        }
        return completed
    }

    private func continueWithoutVoiceDetector(
        from requestedStart: Int
    ) async throws -> [MeetingTranscriptSegment] {
        if !recognizerSegmentIsOpen || currentSpeechStart == nil {
            beginRecognizerSegment(at: requestedStart)
        }
        let completed = try await feedCurrentSpeech(upTo: sessionAudio.endIndex)
        trimRetainedAudio()
        return completed
    }

    private func finishRecognizerSegment() async throws -> MeetingTranscriptSegment? {
        guard recognizerSegmentIsOpen else { return nil }
        let start = currentSpeechStart ?? sessionAudio.startIndex
        let end = currentSpeechFedThrough ?? start
        let audio = sessionAudio.samples(from: start, to: end)
        recognizerSegmentIsOpen = false
        let hasLeadingOverlap = recognizerSegmentHasLeadingOverlap
        recognizerSegmentHasLeadingOverlap = false
        guard !audio.isEmpty else { return nil }
        if speaker == .me,
           echoDetector.isPlaybackOnly(audio, startingAt: start) {
            return nil
        }

        let source: AudioSource = speaker == .me ? .microphone : .system
        let preparedAudio = OfflineRecognitionAudio.paddedToMinimumDuration(audio)
        let result: ASRResult
        do {
            result = try await recognizer.transcribe(preparedAudio, source: source)
        } catch {
            try? await recognizer.resetDecoderState(for: source)
            result = try await recognizer.transcribe(preparedAudio, source: source)
        }

        var text = transcriptProcessor.process(result.text).text
        if hasLeadingOverlap {
            let timedOverlapTokens = result.tokenTimings?.filter {
                $0.startTime <= Double(Self.forcedSegmentOverlapSamples) / Double(Self.sampleRate) + 0.25
            }.count ?? 12
            text = TranscriptSegments.removingLeadingOverlap(
                from: text,
                alreadyConfirmedIn: confirmedText,
                maximumOverlapWords: min(32, max(12, timedOverlapTokens))
            )
        }
        text = TranscriptSegments.capitalizingFirstLetter(
            in: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !text.isEmpty else { return nil }

        confirmedText = TranscriptSegments.appending(
            text,
            to: confirmedText,
            deduplicatingLeadingOverlap: false
        )
        return MeetingTranscriptSegment(
            speaker: speaker,
            startTime: Double(start) / Double(Self.sampleRate),
            endTime: Double(end) / Double(Self.sampleRate),
            text: text
        )
    }

    private func trimRetainedAudio() {
        let retainFrom: Int
        if let currentSpeechStart {
            retainFrom = max(sessionAudio.startIndex, currentSpeechStart)
        } else {
            retainFrom = max(
                sessionAudio.startIndex,
                sessionAudio.endIndex - Self.fallbackTailSamples
            )
        }
        sessionAudio.discard(before: retainFrom)
    }
}

@MainActor
final class MeetingSessionController: ObservableObject {
    static let shared = MeetingSessionController()
    /// System playback is also audible to the microphone. Give the dedicated
    /// system-audio recognizer a moment to claim that speech before presenting
    /// a competing microphone result as "Me".
    private static let echoConfirmationDelay: TimeInterval = 1.5

    @Published private(set) var phase: MeetingSessionPhase = .idle
    @Published var meeting = MeetingRecord(title: "New meeting")
    @Published private(set) var elapsed: TimeInterval = 0

    private var mePipeline: MeetingRecognitionPipeline?
    private var themPipeline: MeetingRecognitionPipeline?
    private let echoDetector = MeetingPlaybackEchoDetector()
    private let micIngress: BoundedAudioIngress
    private let systemIngress: BoundedSystemAudioIngress
    private let microphone: AudioCapture
    private let systemAudio: MeetingSystemAudioCapture
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var microphoneSegmentCommitTask: Task<Void, Never>?
    private var sessionGeneration: UInt = 0
    private var startedAt: Date?
    private var lastAudioActivityAt: Date?
    private var lastSystemAudioActivityAt: Date?
    private var pendingMicrophoneSegments: [MeetingTranscriptSegment] = []
    private var acceptsAudio = false
    #if DEBUG
    private var unreconciledTranscript: [MeetingTranscriptSegment] = []
    private var suppressAutomaticSummaryForSmokeTest = false
    #endif

    private init() {
        let ingress = BoundedAudioIngress(capacity: 512)
        let systemIngress = BoundedSystemAudioIngress(capacity: 512)
        micIngress = ingress
        self.systemIngress = systemIngress
        microphone = AudioCapture(
            prefersVoiceProcessing: true,
            bufferHandler: { generation, buffer in
                ingress.enqueue(generation: generation, buffer: buffer)
            },
            configurationChangeHandler: { generation in
                Task { @MainActor in
                    guard MeetingSessionController.shared.sessionGeneration == generation else { return }
                    await MeetingSessionController.shared.stop(reason: "The microphone changed, so recording stopped.")
                }
            }
        )
        systemAudio = MeetingSystemAudioCapture { captured in systemIngress.enqueue(captured) }
    }

    var isRecording: Bool { phase.isCapturing }
    var isPaused: Bool { phase == .paused }

    func prepare() {
        guard !phase.isCapturing else { return }
        resetEchoPresentationState()
        meeting = MeetingRecord(title: "New meeting")
        phase = .idle
        elapsed = 0
        #if DEBUG
        unreconciledTranscript = []
        #endif
    }

    func start() {
        guard !phase.isCapturing else { return }
        Task { await startSession() }
    }

    func togglePause() {
        switch phase {
        case .recording:
            acceptsAudio = false
            phase = .paused
        case .paused:
            acceptsAudio = true
            phase = .recording
        default:
            break
        }
    }

    func stop() {
        Task { await stop(reason: nil) }
    }

    func updateRawNotes(_ notes: String) {
        meeting.rawNotes = notes
        MeetingStore.shared.saveReportingError(meeting)
    }

    func updateTitle(_ title: String) {
        meeting.title = title
        MeetingStore.shared.saveReportingError(meeting)
    }

    func selectTemplate(_ id: String) {
        meeting.templateID = id
        if let notes = meeting.generatedNotes {
            meeting.generatedNotes = MeetingGeneratedNotesGrounder.grounded(notes, in: meeting)
        }
        MeetingStore.shared.saveReportingError(meeting)
    }

    func saveGeneratedNotes(_ notes: MeetingGeneratedNotes) {
        applyGeneratedNotes(notes)
        guard MeetingStore.shared.saveReportingError(meeting) else {
            phase = .failed("The generated notes could not be saved.")
            return
        }
        if case let .failed(message) = phase,
           message.hasPrefix("Transcript saved, but notes could not be generated:") {
            phase = .complete
        }
    }

    private func startSession() async {
        switch AppState.shared.status {
        case .preparing, .listening:
            phase = .failed("Stop the current dictation before starting Meeting Notes.")
            return
        default:
            break
        }
        resetEchoPresentationState()
        echoDetector.reset()
        phase = .preparing("Requesting microphone access…")
        do {
            try await ensureMicrophonePermission()
            try microphone.validateInputAvailable()
            phase = .preparing("Requesting Screen & System Audio access…")
            MeetingSystemAudioCapture.requestAuthorizationIfNeeded()
            phase = .preparing("Loading meeting transcription models…")
            let recognizer = try await TranscriptionController.shared
                .speechRecognizerForMeeting()
            let voiceDetector = await TranscriptionController.shared
                .voiceDetectorForMeeting()
            let transcriptProcessor = AppState.shared.makeTranscriptProcessor(mode: .polished)
            let pipelines = (
                MeetingRecognitionPipeline(
                    speaker: .me,
                    recognizer: recognizer,
                    voiceDetector: voiceDetector,
                    transcriptProcessor: transcriptProcessor,
                    echoDetector: echoDetector
                ),
                MeetingRecognitionPipeline(
                    speaker: .them,
                    recognizer: recognizer,
                    voiceDetector: voiceDetector,
                    transcriptProcessor: transcriptProcessor,
                    echoDetector: echoDetector
                )
            )
            mePipeline = pipelines.0
            themPipeline = pipelines.1
            await mePipeline?.start()
            await themPipeline?.start()

            sessionGeneration &+= 1
            let generation = sessionGeneration
            let micStream = micIngress.beginSession(generation: generation)
            micTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await packet in micStream where packet.generation == generation {
                    await self.consumeMicrophone(packet.buffer)
                }
            }
            let systemStream = systemIngress.beginSession()
            systemTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await captured in systemStream {
                    await self.consumeSystemAudio(captured)
                }
            }

            phase = .preparing("Starting Mac and microphone audio…")
            // Accept packets before either capture source starts. The streams
            // are already generation-scoped, so buffering setup audio cannot
            // leak a previous meeting and prevents clipping an immediate hello.
            acceptsAudio = true
            let captureStartedAt = Date()
            try await systemAudio.start()
            do {
                try microphone.start(sessionGeneration: generation)
            } catch {
                await systemAudio.stop()
                throw error
            }

            meeting.startedAt = captureStartedAt
            meeting.endedAt = nil
            meeting.transcript = []
            meeting.generatedNotes = nil
            try MeetingStore.shared.save(meeting)
            startedAt = meeting.startedAt
            lastAudioActivityAt = meeting.startedAt
            phase = .recording
            startElapsedTimer()
        } catch {
            acceptsAudio = false
            microphone.stop()
            await systemAudio.stop()
            micIngress.finishSession(generation: sessionGeneration)
            systemIngress.finishSession()
            await micTask?.value
            await systemTask?.value
            micTask = nil
            systemTask = nil
            phase = .failed(Self.friendlyCaptureMessage(for: error))
            mePipeline = nil
            themPipeline = nil
            TranscriptionController.shared.meetingRecognitionDidEnd()
        }
    }

    fileprivate func stop(reason: String?) async {
        guard phase.isCapturing else { return }
        var finalizationReason = reason
        phase = .finalizing("Finishing transcript…")
        elapsedTask?.cancel()
        microphoneSegmentCommitTask?.cancel()
        microphoneSegmentCommitTask = nil
        microphone.stop()
        await systemAudio.stop()
        let droppedMicrophoneAudio = micIngress.finishSession(generation: sessionGeneration)
        let droppedSystemAudio = systemIngress.finishSession()
        await micTask?.value
        await systemTask?.value
        micTask = nil
        systemTask = nil
        acceptsAudio = false

        var finalSegments: [MeetingTranscriptSegment] = []
        do {
            finalSegments.append(contentsOf: try await themPipeline?.finish() ?? [])
        } catch {
            finalizationReason = finalizationReason
                ?? "System-audio transcription failed while finishing: \(error.localizedDescription)"
        }
        do {
            finalSegments.append(contentsOf: try await mePipeline?.finish() ?? [])
        } catch {
            finalizationReason = finalizationReason
                ?? "Microphone transcription failed while finishing: \(error.localizedDescription)"
        }
        appendTranscriptSegments(finalSegments)
        flushPendingMicrophoneSegments()
        meeting.endedAt = Date()
        mePipeline = nil
        themPipeline = nil
        TranscriptionController.shared.meetingRecognitionDidEnd()

        do {
            try MeetingStore.shared.save(meeting)
            if meeting.transcript.isEmpty {
                phase = .failed(finalizationReason ?? "No speech was detected in this meeting.")
            } else {
                #if DEBUG
                if suppressAutomaticSummaryForSmokeTest {
                    phase = .complete
                } else {
                    await generateNotes()
                }
                #else
                await generateNotes()
                #endif
                if droppedMicrophoneAudio || droppedSystemAudio, phase == .complete {
                    phase = .failed("Meeting saved, but audio processing fell behind and part of the transcript may be missing.")
                }
                if let finalizationReason, phase == .complete {
                    phase = .failed(finalizationReason)
                }
            }
        } catch {
            phase = .failed("The meeting ended, but its notes could not be saved: \(error.localizedDescription)")
        }
    }

    private func generateNotes() async {
        phase = .finalizing("Generating trustworthy notes…")
        let generatedNotes: MeetingGeneratedNotes
        do {
            generatedNotes = try await MeetingAIService.generateNotes(
                for: meeting,
                progress: { [weak self] message in self?.phase = .finalizing(message) }
            )
        } catch MeetingAIError.modelUnavailable {
            // A transcript without configured AI is still a completed, useful meeting.
            phase = MeetingStore.shared.saveReportingError(meeting)
                ? .complete
                : .failed("The transcript could not be saved.")
            return
        } catch {
            let saved = MeetingStore.shared.saveReportingError(meeting)
            phase = saved
                ? .failed("Transcript saved, but notes could not be generated: \(error.localizedDescription)")
                : .failed("The transcript could not be saved, and notes could not be generated: \(error.localizedDescription)")
            return
        }

        applyGeneratedNotes(generatedNotes)
        do {
            try MeetingStore.shared.save(meeting)
            phase = .complete
        } catch {
            phase = .failed("The notes were generated but could not be saved: \(error.localizedDescription)")
        }
    }

    private func applyGeneratedNotes(_ notes: MeetingGeneratedNotes) {
        meeting.generatedNotes = notes
        if meeting.needsGeneratedTitle, let suggestedTitle = notes.suggestedTitle {
            meeting.title = suggestedTitle
        }
    }

    private func consumeMicrophone(_ buffer: AVAudioPCMBuffer) async {
        guard acceptsAudio, let pipeline = mePipeline else { return }
        do {
            appendTranscriptSegments(try await pipeline.consume(buffer))
            if pipeline.recentlyHadAudio { lastAudioActivityAt = Date() }
        } catch {
            let message = "Microphone transcription failed: \(error.localizedDescription)"
            Task { @MainActor [weak self] in
                await self?.stop(reason: message)
            }
        }
    }

    private func consumeSystemAudio(_ captured: CapturedSystemAudioBuffer) async {
        guard acceptsAudio, let pipeline = themPipeline else { return }
        do {
            let buffer = try MeetingSystemAudioCapture.pcmBuffer(from: captured)
            appendTranscriptSegments(try await pipeline.consume(buffer))
            if pipeline.recentlyHadAudio {
                let now = Date()
                lastAudioActivityAt = now
                lastSystemAudioActivityAt = now
            }
        } catch {
            let message = "System-audio transcription failed: \(error.localizedDescription)"
            Task { @MainActor [weak self] in
                await self?.stop(reason: message)
            }
        }
    }

    private func appendTranscriptSegments(_ segments: [MeetingTranscriptSegment]) {
        guard !segments.isEmpty else { return }
        #if DEBUG
        unreconciledTranscript.append(contentsOf: segments)
        #endif

        let microphoneSegments = segments.filter { $0.speaker == .me }
        let immediateSegments = segments.filter { $0.speaker != .me }

        if !immediateSegments.isEmpty {
            // If the microphone reached the segment boundary first, its result
            // is waiting here. Reconcile both sources atomically so the UI
            // never flashes the system speech as Me.
            microphoneSegmentCommitTask?.cancel()
            microphoneSegmentCommitTask = nil
            meeting.transcript = MeetingTranscriptReconciler.reconcile(
                meeting.transcript + immediateSegments + pendingMicrophoneSegments
            )
            pendingMicrophoneSegments.removeAll()
        }

        guard !microphoneSegments.isEmpty else { return }
        if systemAudioConfirmationDelayRemaining > 0 {
            pendingMicrophoneSegments.append(contentsOf: microphoneSegments)
            schedulePendingMicrophoneCommit()
        } else {
            meeting.transcript = MeetingTranscriptReconciler.reconcile(
                meeting.transcript + microphoneSegments
            )
        }
    }

    private var systemAudioConfirmationDelayRemaining: TimeInterval {
        guard let lastSystemAudioActivityAt else { return 0 }
        return max(
            0,
            Self.echoConfirmationDelay - Date().timeIntervalSince(lastSystemAudioActivityAt)
        )
    }

    private func schedulePendingMicrophoneCommit() {
        microphoneSegmentCommitTask?.cancel()
        let delay = max(systemAudioConfirmationDelayRemaining, Self.echoConfirmationDelay)
        let generation = sessionGeneration
        microphoneSegmentCommitTask = Task { @MainActor [weak self] in
            let milliseconds = Int64((delay * 1_000).rounded(.up))
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled,
                  let self,
                  self.sessionGeneration == generation else { return }
            guard self.systemAudioConfirmationDelayRemaining == 0 else {
                self.schedulePendingMicrophoneCommit()
                return
            }
            self.flushPendingMicrophoneSegments()
        }
    }

    private func flushPendingMicrophoneSegments() {
        microphoneSegmentCommitTask?.cancel()
        microphoneSegmentCommitTask = nil
        guard !pendingMicrophoneSegments.isEmpty else { return }
        meeting.transcript = MeetingTranscriptReconciler.reconcile(
            meeting.transcript + pendingMicrophoneSegments
        )
        pendingMicrophoneSegments.removeAll()
    }

    private func resetEchoPresentationState() {
        microphoneSegmentCommitTask?.cancel()
        microphoneSegmentCommitTask = nil
        pendingMicrophoneSegments.removeAll()
        lastSystemAudioActivityAt = nil
    }

    #if DEBUG
    func runAudioSeparationSmokeTest() async -> MeetingAudioSeparationSmokeTestResult {
        let systemPhrase = "Crimson lanterns drift quietly across the silver harbor. This sentence tests system audio separation."
        let systemMarkerWords = Set([
            "crimson", "lanterns", "silver", "harbor",
            "system", "audio", "separation",
        ])
        let microphonePhrase = "Copper bicycles circle beneath the golden mountain. This sentence tests microphone capture."
        let microphoneMarkerWords = Set([
            "copper", "bicycles", "golden", "mountain",
            "sentence", "tests", "microphone", "capture",
        ])

        prepare()
        suppressAutomaticSummaryForSmokeTest = true
        start()
        for _ in 0..<1_200 {
            if phase == .recording { break }
            if case .failed = phase { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard phase == .recording else {
            suppressAutomaticSummaryForSmokeTest = false
            return MeetingAudioSeparationSmokeTestResult(
                succeeded: false,
                message: "Meeting capture could not start: \(smokeTestPhaseDescription)"
            )
        }

        do {
            // First prove that Mac playback is retained as Them and removed
            // from Me by transcript reconciliation.
            try await Task.sleep(for: .seconds(2))
            guard try await Self.playSmokeTestPhrase(systemPhrase) else {
                await stop(reason: nil)
                suppressAutomaticSummaryForSmokeTest = false
                _ = MeetingStore.shared.delete(meeting)
                return MeetingAudioSeparationSmokeTestResult(
                    succeeded: false,
                    message: "The system-audio test phrase could not be played."
                )
            }
            try await Task.sleep(for: .seconds(5))

            // Stop the system stream, then inject a deterministic synthesized
            // buffer through the meeting's microphone recognition path. The
            // separate Dictation smoke test exercises the physical mic;
            // this avoids making the separation test depend on speaker volume,
            // headphones, or room acoustics.
            await systemAudio.stop()
            try await Task.sleep(for: .seconds(1))
            let microphoneBuffer = try await Self.synthesizedSmokeTestBuffer(
                microphonePhrase
            )
            await consumeMicrophone(microphoneBuffer)
            try await Task.sleep(for: .seconds(2))
        } catch {
            await stop(reason: nil)
            suppressAutomaticSummaryForSmokeTest = false
            _ = MeetingStore.shared.delete(meeting)
            return MeetingAudioSeparationSmokeTestResult(
                succeeded: false,
                message: "The system-audio test was interrupted: \(error.localizedDescription)"
            )
        }

        await stop(reason: nil)
        suppressAutomaticSummaryForSmokeTest = false

        let rawMe = unreconciledTranscript
            .filter { $0.speaker == .me }
            .map(\.text)
            .joined(separator: " ")
        let rawThem = unreconciledTranscript
            .filter { $0.speaker == .them }
            .map(\.text)
            .joined(separator: " ")
        let rawSystemMeMarkers = Self.markerCount(in: rawMe, markers: systemMarkerWords)
        let rawSystemThemMarkers = Self.markerCount(in: rawThem, markers: systemMarkerWords)
        let rawMicrophoneMeMarkers = Self.markerCount(in: rawMe, markers: microphoneMarkerWords)
        let reconciledMe = meeting.transcript
            .filter { $0.speaker == .me }
            .map(\.text)
            .joined(separator: " ")
        let reconciledThem = meeting.transcript
            .filter { $0.speaker == .them }
            .map(\.text)
            .joined(separator: " ")
        let reconciledSystemMeMarkers = Self.markerCount(
            in: reconciledMe,
            markers: systemMarkerWords
        )
        let reconciledSystemThemMarkers = Self.markerCount(
            in: reconciledThem,
            markers: systemMarkerWords
        )
        let reconciledMicrophoneMeMarkers = Self.markerCount(
            in: reconciledMe,
            markers: microphoneMarkerWords
        )
        let passed = reconciledSystemThemMarkers >= 4
            && reconciledSystemMeMarkers <= 1
            && reconciledMicrophoneMeMarkers >= 4
        let rawMeSegments = unreconciledTranscript.filter { $0.speaker == .me }.count
        let rawThemSegments = unreconciledTranscript.filter { $0.speaker == .them }.count
        let testMeeting = meeting
        let cleanedUp = MeetingStore.shared.delete(testMeeting)

        return MeetingAudioSeparationSmokeTestResult(
            succeeded: passed && cleanedUp,
            message: "systemThem=\(reconciledSystemThemMarkers) systemMe=\(reconciledSystemMeMarkers) microphoneMe=\(reconciledMicrophoneMeMarkers) rawSystemThem=\(rawSystemThemMarkers) rawSystemMe=\(rawSystemMeMarkers) rawMicrophoneMe=\(rawMicrophoneMeMarkers) rawThemSegments=\(rawThemSegments) rawMeSegments=\(rawMeSegments) voiceProcessing=\(microphone.isVoiceProcessingActive) audioEchoSuppressed=\(echoDetector.suppressedSegmentCount) cleanup=\(cleanedUp)"
        )
    }

    private static func playSmokeTestPhrase(_ phrase: String) async throws -> Bool {
        let speaker = Process()
        speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speaker.arguments = ["-r", "150", phrase]
        try speaker.run()
        while speaker.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        return speaker.terminationStatus == 0
    }

    private static func synthesizedSmokeTestBuffer(
        _ phrase: String
    ) async throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yaprflow-meeting-microphone-\(UUID().uuidString).aiff"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let speaker = Process()
        speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speaker.arguments = ["-r", "150", "-o", url.path, phrase]
        try speaker.run()
        while speaker.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard speaker.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }

        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func markerCount(in text: String, markers: Set<String>) -> Int {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return words.intersection(markers).count
    }

    private var smokeTestPhaseDescription: String {
        switch phase {
        case .idle: "idle"
        case let .preparing(message): message
        case .recording: "recording"
        case .paused: "paused"
        case let .finalizing(message): message
        case .complete: "complete"
        case let .failed(message): message
        }
    }
    #endif

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                if self.phase == .recording,
                   let lastActivity = self.lastAudioActivityAt,
                   Date().timeIntervalSince(lastActivity) >= 15 * 60 {
                    await self.stop(reason: "Recording stopped after 15 minutes without audible conversation.")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw TranscriptionError.microphoneDenied
            }
        case .denied, .restricted:
            throw TranscriptionError.microphoneDenied
        @unknown default:
            throw TranscriptionError.microphoneDenied
        }
    }

    private static func friendlyCaptureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code) {
            switch code {
            case .userDeclined:
                return MeetingSystemAudioError.permissionDenied.localizedDescription
            case .failedToStartAudioCapture:
                return "Mac audio could not start. Reconnect the current audio device or restart Yaprflow, then try again."
            default:
                return "Mac audio capture could not start. Restart Yaprflow and try again."
            }
        }
        return error.localizedDescription
    }
}
