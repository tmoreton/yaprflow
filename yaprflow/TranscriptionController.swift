import AVFoundation
import AppKit
import CoreML
import FluidAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Transcription")

enum TranscriptionError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access denied"
        }
    }
}

@MainActor
final class TranscriptionController {
    static let shared = TranscriptionController()

    private let state = AppState.shared
    private let capture: AudioCapture
    private let audioConverter = AudioConverter()

    // Models are loaded once and kept for the process lifetime
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var loadingTask: Task<(AsrManager, VadManager), Error>?

    // Per-session state
    private var sessionSamples: [Float] = []
    private var vadPending: [Float] = []
    private var vadState: VadStreamState?
    private var currentSpeechStart: Int?
    private var confirmedText = ""
    private var transcribeChain: Task<Void, Never>?

    private var isActive = false
    private var isStarting = false
    private var autoHideTask: Task<Void, Never>?

    // Tighter than SDK default (0.75s) so dictation feels snappy.
    private let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.4,
        maxSpeechDuration: 12.0,
        speechPadding: 0.1
    )

    private init() {
        let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            Task { @MainActor in
                await TranscriptionController.shared.feed(buffer)
            }
        }
        self.capture = AudioCapture(bufferHandler: bufferHandler)
    }

    func toggle() {
        Task { @MainActor in
            if isActive {
                await stop()
            } else {
                await start()
            }
        }
    }

    private func start() async {
        guard !isActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        autoHideTask?.cancel()
        confirmedText = ""
        state.liveTranscript = ""
        NotchOverlayWindowController.shared.show()

        do {
            try await ensureMicPermission()
            let (_, vad) = try await ensureLoaded()

            sessionSamples.removeAll(keepingCapacity: true)
            vadPending.removeAll(keepingCapacity: true)
            vadState = await vad.makeStreamState()
            currentSpeechStart = nil

            state.status = .listening
            try capture.start()
            isActive = true
        } catch {
            log.error("Start failed: \(error.localizedDescription)")
            state.status = .error(error.localizedDescription)
            scheduleAutoHide(after: 2.5)
        }
    }

    private func stop() async {
        guard isActive else { return }
        isActive = false
        capture.stop()
        state.status = .finishing

        // If user was still speaking when they released the hotkey, flush the
        // remaining audio through the transcriber so nothing is lost.
        if let start = currentSpeechStart, start < sessionSamples.count {
            let tail = Array(sessionSamples[start..<sessionSamples.count])
            currentSpeechStart = nil
            enqueueTranscribe(samples: tail)
        }

        // Wait for all queued segments to finish transcribing before reading
        // confirmedText for the clipboard.
        await transcribeChain?.value

        let finalText = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.liveTranscript = finalText

        if !finalText.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(finalText, forType: .string)
            state.status = .copied
        } else {
            state.status = .idle
        }
        scheduleAutoHide(after: 1.2)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard isActive, let vad = vadManager, var currentVadState = vadState else { return }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleBuffer(buffer)
        } catch {
            log.error("Resample failed: \(error.localizedDescription)")
            return
        }

        sessionSamples.append(contentsOf: samples)
        vadPending.append(contentsOf: samples)

        while vadPending.count >= VadManager.chunkSize {
            let chunk = Array(vadPending.prefix(VadManager.chunkSize))
            vadPending.removeFirst(VadManager.chunkSize)

            let result: VadStreamResult
            do {
                result = try await vad.processStreamingChunk(
                    chunk,
                    state: currentVadState,
                    config: segmentationConfig
                )
            } catch {
                log.error("VAD failed: \(error.localizedDescription)")
                return
            }
            currentVadState = result.state
            vadState = currentVadState

            guard let event = result.event else { continue }
            switch event.kind {
            case .speechStart:
                currentSpeechStart = event.sampleIndex
            case .speechEnd:
                guard let start = currentSpeechStart else { continue }
                let clampedStart = max(0, min(start, sessionSamples.count))
                let clampedEnd = max(clampedStart, min(event.sampleIndex, sessionSamples.count))
                currentSpeechStart = nil
                guard clampedEnd > clampedStart else { continue }
                let segment = Array(sessionSamples[clampedStart..<clampedEnd])
                enqueueTranscribe(samples: segment)
            }
        }
    }

    /// Transcribe segments in the order they arrive by chaining Tasks.
    private func enqueueTranscribe(samples: [Float]) {
        let previous = transcribeChain
        transcribeChain = Task { [weak self] in
            await previous?.value
            await self?.performTranscribe(samples: samples)
        }
    }

    private func performTranscribe(samples: [Float]) async {
        guard let asr = asrManager else { return }
        do {
            let result = try await asr.transcribe(samples, source: .microphone)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            await MainActor.run {
                if self.confirmedText.isEmpty {
                    self.confirmedText = trimmed
                } else {
                    self.confirmedText += " " + trimmed
                }
                self.state.liveTranscript = self.confirmedText
            }
        } catch {
            log.error("Transcribe failed: \(error.localizedDescription)")
        }
    }

    private func ensureMicPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw TranscriptionError.microphoneDenied
        case .denied, .restricted:
            throw TranscriptionError.microphoneDenied
        @unknown default:
            throw TranscriptionError.microphoneDenied
        }
    }

    private func ensureLoaded() async throws -> (AsrManager, VadManager) {
        if let asr = asrManager, let vad = vadManager { return (asr, vad) }
        if let existing = loadingTask {
            return try await existing.value
        }

        state.status = .preparing("Loading transcription model…")

        let task = Task<(AsrManager, VadManager), Error> { @MainActor in
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine

            let asrModels: AsrModels
            if let bundled = Self.bundledModelURL() {
                log.info("Loading bundled ASR model from \(bundled.path, privacy: .public)")
                asrModels = try await AsrModels.load(
                    from: bundled,
                    configuration: mlConfig,
                    version: .v2
                )
            } else {
                log.info("Downloading Parakeet TDT 0.6B v2 from HuggingFace")
                state.status = .preparing("Downloading model…")
                asrModels = try await AsrModels.downloadAndLoad(
                    configuration: mlConfig,
                    version: .v2,
                    progressHandler: { progress in
                        let pct = Int((progress.fractionCompleted * 100).rounded())
                        Task { @MainActor in
                            AppState.shared.status = .preparing("Downloading model… \(pct)%")
                        }
                    }
                )
            }

            let asr = AsrManager(config: .default)
            try await asr.loadModels(asrModels)

            state.status = .preparing("Loading voice detector…")
            let vadConfig = VadConfig(computeUnits: .cpuAndNeuralEngine)
            let vad = try await VadManager(config: vadConfig)

            return (asr, vad)
        }
        loadingTask = task

        do {
            let (asr, vad) = try await task.value
            self.asrManager = asr
            self.vadManager = vad
            return (asr, vad)
        } catch {
            loadingTask = nil
            throw error
        }
    }

    private static let modelSubpath = "Models/parakeet-tdt-0.6b-v2-coreml"
    private static let requiredModelFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    private static func bundledModelURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent(modelSubpath, isDirectory: true)
        let fm = FileManager.default
        for file in requiredModelFiles where !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return nil
        }
        return dir
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
            state.liveTranscript = ""
            NotchOverlayWindowController.shared.hide()
        }
    }
}
