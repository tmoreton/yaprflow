@preconcurrency import AVFoundation
import AppKit
import Combine
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

@MainActor
private final class MeetingRecognitionPipeline {
    private static let maximumSegmentSamples = 25 * NemotronStreamingRecognizer.sampleRate

    let speaker: MeetingSpeaker
    private let recognizer: NemotronStreamingRecognizer
    private let converter = StreamingAudioConverter()
    private let language: SpeechLanguage
    private var segmentStartSample = 0
    private var segmentSampleCount = 0
    private var totalSampleCount = 0
    private(set) var liveText = ""
    private(set) var recentlyHadAudio = false

    init(
        speaker: MeetingSpeaker,
        recognizer: NemotronStreamingRecognizer,
        language: SpeechLanguage
    ) {
        self.speaker = speaker
        self.recognizer = recognizer
        self.language = language
    }

    func start() async {
        converter.reset()
        segmentStartSample = 0
        segmentSampleCount = 0
        totalSampleCount = 0
        liveText = ""
        await recognizer.beginStream(language: language)
    }

    func consume(_ buffer: AVAudioPCMBuffer) async throws -> [MeetingTranscriptSegment] {
        try await consume(samples: converter.resampleBuffer(buffer))
    }

    func finish() async -> [MeetingTranscriptSegment] {
        guard segmentSampleCount > 0 else {
            await recognizer.discardStream()
            return []
        }
        let finalText = await recognizer.finishStream()
        liveText = ""
        return makeSegment(text: finalText).map { [$0] } ?? []
    }

    private func consume(samples: [Float]) async throws -> [MeetingTranscriptSegment] {
        if samples.isEmpty {
            recentlyHadAudio = false
        } else {
            let meanSquare = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
            recentlyHadAudio = meanSquare > 0.000_025
        }
        var completed: [MeetingTranscriptSegment] = []
        var offset = 0
        while offset < samples.count {
            let remaining = Self.maximumSegmentSamples - segmentSampleCount
            let count = min(remaining, samples.count - offset)
            let part = Array(samples[offset..<(offset + count)])
            liveText = await recognizer.accept(part)
            segmentSampleCount += count
            totalSampleCount += count
            offset += count

            if segmentSampleCount >= Self.maximumSegmentSamples {
                let text = await recognizer.finishStream()
                if let segment = makeSegment(text: text) { completed.append(segment) }
                segmentStartSample = totalSampleCount
                segmentSampleCount = 0
                liveText = ""
                await recognizer.beginStream(language: language)
            }
        }
        return completed
    }

    private func makeSegment(text: String) -> MeetingTranscriptSegment? {
        let polished = TranscriptPolishing.polish(text)
        guard !polished.isEmpty else { return nil }
        return MeetingTranscriptSegment(
            speaker: speaker,
            startTime: Double(segmentStartSample) / Double(NemotronStreamingRecognizer.sampleRate),
            endTime: Double(totalSampleCount) / Double(NemotronStreamingRecognizer.sampleRate),
            text: TranscriptSegments.capitalizingFirstLetter(in: polished)
        )
    }
}

@MainActor
final class MeetingSessionController: ObservableObject {
    static let shared = MeetingSessionController()

    @Published private(set) var phase: MeetingSessionPhase = .idle
    @Published var meeting = MeetingRecord(title: "New meeting")
    @Published private(set) var liveMe = ""
    @Published private(set) var liveThem = ""
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
    private var sessionGeneration: UInt = 0
    private var startedAt: Date?
    private var lastAudioActivityAt: Date?
    private var acceptsAudio = false

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
        liveMe = ""
        liveThem = ""
        elapsed = 0
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
        phase = .preparing("Requesting microphone access…")
        do {
            try await ensureMicrophonePermission()
            try microphone.validateInputAvailable()
            phase = .preparing("Loading meeting transcription models…")
            let directory = try Self.bundledModelDirectory()
            async let meRecognizer = Task.detached(priority: .userInitiated) {
                try NemotronStreamingRecognizer(modelDirectory: directory)
            }.value
            async let themRecognizer = Task.detached(priority: .userInitiated) {
                try NemotronStreamingRecognizer(modelDirectory: directory)
            }.value
            let pipelines = try await (
                MeetingRecognitionPipeline(
                    speaker: .me,
                    recognizer: meRecognizer,
                    language: AppState.shared.speechLanguage
                ),
                MeetingRecognitionPipeline(
                    speaker: .them,
                    recognizer: themRecognizer,
                    language: AppState.shared.speechLanguage
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
        }
    }

    fileprivate func stop(reason: String?) async {
        guard phase.isCapturing else { return }
        phase = .finalizing("Finishing transcript…")
        elapsedTask?.cancel()
        automaticStopTask?.cancel()
        microphone.stop()
        await systemAudio.stop()
        let droppedMicrophoneAudio = micIngress.finishSession(generation: sessionGeneration)
        let droppedSystemAudio = systemIngress.finishSession()
        await micTask?.value
        await systemTask?.value
        micTask = nil
        systemTask = nil
        acceptsAudio = false

        let meSegments = await mePipeline?.finish() ?? []
        let themSegments = await themPipeline?.finish() ?? []
        meeting.transcript.append(contentsOf: meSegments + themSegments)
        meeting.transcript.sort {
            if $0.startTime == $1.startTime { return $0.speaker.rawValue < $1.speaker.rawValue }
            return $0.startTime < $1.startTime
        }
        meeting.endedAt = Date()
        liveMe = ""
        liveThem = ""
        mePipeline = nil
        themPipeline = nil

        do {
            try MeetingStore.shared.save(meeting)
            if meeting.transcript.isEmpty {
                phase = .failed(reason ?? "No speech was detected in this meeting.")
            } else {
                await generateNotes()
                if droppedMicrophoneAudio || droppedSystemAudio, phase == .complete {
                    phase = .failed("Meeting saved, but audio processing fell behind and part of the transcript may be missing.")
                }
                if let reason, phase == .complete { phase = .failed(reason) }
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
            meeting.transcript.append(contentsOf: try await pipeline.consume(buffer))
            if pipeline.recentlyHadAudio { lastAudioActivityAt = Date() }
            liveMe = pipeline.liveText
        } catch {
            await stop(reason: "Microphone transcription failed: \(error.localizedDescription)")
        }
    }

    private func consumeSystemAudio(_ captured: CapturedSystemAudioBuffer) async {
        guard acceptsAudio, let pipeline = themPipeline else { return }
        do {
            let buffer = try MeetingSystemAudioCapture.pcmBuffer(from: captured)
            meeting.transcript.append(contentsOf: try await pipeline.consume(buffer))
            if pipeline.recentlyHadAudio { lastAudioActivityAt = Date() }
            liveThem = pipeline.liveText
        } catch {
            await stop(reason: "System-audio transcription failed: \(error.localizedDescription)")
        }
    }

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

    private static func bundledModelDirectory() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = resources.appendingPathComponent(
            BundledModelInventory.speechDirectory,
            isDirectory: true
        )
        for file in BundledModelInventory.speechFiles {
            let url = directory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NemotronRecognizerError.incompleteModel(url)
            }
        }
        return directory
    }

    private static func friendlyCaptureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            return "Allow Screen & System Audio Recording for Yaprflow in System Settings, then try again."
        }
        return error.localizedDescription
    }
}
