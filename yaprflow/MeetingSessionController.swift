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

    let speaker: MeetingSpeaker
    private let recognizer: AsrManager
    private let converter = StreamingAudioConverter()
    private var segmentSamples: [Float] = []
    private var segmentStartSample = 0
    private var segmentFirstAudibleSample: Int?
    private var totalSampleCount = 0
    private(set) var recentlyHadAudio = false

    init(
        speaker: MeetingSpeaker,
        recognizer: AsrManager
    ) {
        self.speaker = speaker
        self.recognizer = recognizer
    }

    func start() {
        converter.reset()
        segmentSamples.removeAll(keepingCapacity: true)
        segmentSamples.reserveCapacity(Self.maximumSegmentSamples)
        segmentStartSample = 0
        segmentFirstAudibleSample = nil
        totalSampleCount = 0
    }

    func consume(_ buffer: AVAudioPCMBuffer) async throws -> [MeetingTranscriptSegment] {
        try await consume(samples: converter.resampleBuffer(buffer))
    }

    func finish() async throws -> [MeetingTranscriptSegment] {
        guard !segmentSamples.isEmpty else { return [] }
        return try await transcribeCurrentSegment().map { [$0] } ?? []
    }

    private func consume(samples: [Float]) async throws -> [MeetingTranscriptSegment] {
        var completed: [MeetingTranscriptSegment] = []
        var offset = 0
        var hadAudibleAudio = false
        while offset < samples.count {
            let remaining = Self.maximumSegmentSamples - segmentSamples.count
            let count = min(remaining, samples.count - offset)
            let part = Array(samples[offset..<(offset + count)])
            let meanSquare = part.reduce(0.0) { $0 + Double($1 * $1) } / Double(part.count)
            let isAudible = meanSquare > 0.000_025
            if isAudible {
                hadAudibleAudio = true
                if segmentFirstAudibleSample == nil {
                    segmentFirstAudibleSample = totalSampleCount
                }
            }
            segmentSamples.append(contentsOf: part)
            totalSampleCount += count
            offset += count

            if segmentSamples.count >= Self.maximumSegmentSamples {
                if let segment = try await transcribeCurrentSegment() {
                    completed.append(segment)
                }
                segmentStartSample = totalSampleCount
                segmentFirstAudibleSample = nil
            }
        }
        recentlyHadAudio = hadAudibleAudio
        return completed
    }

    private func transcribeCurrentSegment() async throws -> MeetingTranscriptSegment? {
        guard !segmentSamples.isEmpty else { return nil }
        let audio = segmentSamples
        segmentSamples.removeAll(keepingCapacity: true)
        let source: AudioSource = speaker == .me ? .microphone : .system
        let result = try await recognizer.transcribe(audio, source: source)
        return makeSegment(text: result.text)
    }

    private func makeSegment(text: String) -> MeetingTranscriptSegment? {
        let polished = TranscriptPolishing.polish(text)
        guard !polished.isEmpty else { return nil }
        return MeetingTranscriptSegment(
            speaker: speaker,
            startTime: Double(segmentFirstAudibleSample ?? segmentStartSample)
                / Double(Self.sampleRate),
            endTime: Double(totalSampleCount) / Double(Self.sampleRate),
            text: TranscriptSegments.capitalizingFirstLetter(in: polished)
        )
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
    private let micIngress: BoundedAudioIngress
    private let systemIngress: BoundedSystemAudioIngress
    private let microphone: AudioCapture
    private let systemAudio: MeetingSystemAudioCapture
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var automaticStopTask: Task<Void, Never>?
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

    func prepare(calendarMeeting: CalendarMeeting? = nil) {
        guard !phase.isCapturing else { return }
        resetEchoPresentationState()
        if let event = calendarMeeting {
            meeting = MeetingRecord(
                title: event.title,
                calendarEventIdentifier: event.id,
                recurrenceIdentifier: event.recurrenceIdentifier,
                scheduledStart: event.startDate,
                scheduledEnd: event.endDate,
                attendees: event.attendees
            )
        } else {
            meeting = MeetingRecord(title: "New meeting")
        }
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
        _ = try? MeetingStore.shared.save(meeting)
    }

    func updateTitle(_ title: String) {
        meeting.title = title
        _ = try? MeetingStore.shared.save(meeting)
    }

    func selectTemplate(_ id: String) {
        meeting.templateID = id
        if let notes = meeting.generatedNotes {
            meeting.generatedNotes = MeetingGeneratedNotesGrounder.grounded(notes, in: meeting)
        }
        _ = try? MeetingStore.shared.save(meeting)
    }

    func saveGeneratedNotes(_ notes: MeetingGeneratedNotes) {
        applyGeneratedNotes(notes)
        _ = try? MeetingStore.shared.save(meeting)
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
        phase = .preparing("Requesting microphone access…")
        do {
            try await ensureMicrophonePermission()
            try microphone.validateInputAvailable()
            phase = .preparing("Requesting Screen & System Audio access…")
            MeetingSystemAudioCapture.requestAuthorizationIfNeeded()
            phase = .preparing("Loading meeting transcription models…")
            let recognizer = try await TranscriptionController.shared
                .speechRecognizerForMeeting()
            let pipelines = (
                MeetingRecognitionPipeline(speaker: .me, recognizer: recognizer),
                MeetingRecognitionPipeline(speaker: .them, recognizer: recognizer)
            )
            mePipeline = pipelines.0
            themPipeline = pipelines.1
            mePipeline?.start()
            themPipeline?.start()

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
            try await systemAudio.start()
            do {
                try microphone.start(sessionGeneration: generation)
            } catch {
                await systemAudio.stop()
                throw error
            }

            meeting.startedAt = Date()
            meeting.endedAt = nil
            meeting.transcript = []
            meeting.generatedNotes = nil
            try MeetingStore.shared.save(meeting)
            startedAt = meeting.startedAt
            lastAudioActivityAt = meeting.startedAt
            acceptsAudio = true
            phase = .recording
            startElapsedTimer()
            scheduleAutomaticStop()
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
        automaticStopTask?.cancel()
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

        do {
            let meSegments = try await mePipeline?.finish() ?? []
            let themSegments = try await themPipeline?.finish() ?? []
            appendTranscriptSegments(meSegments + themSegments)
        } catch {
            finalizationReason = finalizationReason
                ?? "Meeting transcription failed: \(error.localizedDescription)"
        }
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
        do {
            let notes = try await MeetingAIService.generateNotes(
                for: meeting,
                progress: { [weak self] message in self?.phase = .finalizing(message) }
            )
            applyGeneratedNotes(notes)
            try MeetingStore.shared.save(meeting)
            phase = .complete
        } catch MeetingAIError.modelUnavailable {
            _ = try? MeetingStore.shared.save(meeting)
            // A transcript without configured AI is still a completed, useful meeting.
            phase = .complete
        } catch {
            _ = try? MeetingStore.shared.save(meeting)
            phase = .failed("Transcript saved, but notes could not be generated: \(error.localizedDescription)")
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
            await stop(reason: "Microphone transcription failed: \(error.localizedDescription)")
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
            await stop(reason: "System-audio transcription failed: \(error.localizedDescription)")
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
            // separate Quick Dictation smoke test exercises the physical mic;
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
            message: "systemThem=\(reconciledSystemThemMarkers) systemMe=\(reconciledSystemMeMarkers) microphoneMe=\(reconciledMicrophoneMeMarkers) rawSystemThem=\(rawSystemThemMarkers) rawSystemMe=\(rawSystemMeMarkers) rawMicrophoneMe=\(rawMicrophoneMeMarkers) rawThemSegments=\(rawThemSegments) rawMeSegments=\(rawMeSegments) cleanup=\(cleanedUp)"
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

    private func scheduleAutomaticStop() {
        guard let scheduledEnd = meeting.scheduledEnd else { return }
        let stopDate = scheduledEnd.addingTimeInterval(15 * 60)
        guard stopDate > Date() else { return }
        automaticStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(stopDate.timeIntervalSinceNow))
            } catch { return }
            await self?.stop(reason: "Recording stopped 15 minutes after the scheduled meeting ended.")
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
