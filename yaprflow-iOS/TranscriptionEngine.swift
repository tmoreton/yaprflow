#if os(iOS)
@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import OSLog
import UIKit

private let log = Logger(subsystem: "com.tmoreton.yaprflow.ios", category: "Transcription")

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

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case finishing
    case copied
    case error(String)
}

@MainActor
final class TranscriptionEngine: ObservableObject {
    static let shared = TranscriptionEngine()

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""

    /// Rolling history of recent normalized audio levels (0...1). Updated at
    /// roughly the audio buffer rate while recording, decays toward zero when
    /// idle. Size is fixed; SwiftUI renders this directly as a bar waveform.
    @Published var levels: [Float] = Array(repeating: 0, count: TranscriptionEngine.levelCount)
    static let levelCount = 80

    private let history = HistoryStore.shared
    private let capture: AudioCapture
    private let audioConverter = AudioConverter()

    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var loadingTask: Task<(AsrManager, VadManager), Error>?

    // Per-session state
    private var sessionSamples: [Float] = []
    private var vadPending: [Float] = []
    private var vadState: VadStreamState?
    private var currentSpeechStart: Int?
    private var confirmedText = ""
    private var volatileText = ""
    private var lastSpeculativeSampleCount = 0
    private var transcribeChain: Task<Void, Never>?

    private var isActive = false
    private var isStarting = false
    private var autoHideTask: Task<Void, Never>?

    private let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.3,
        maxSpeechDuration: 60.0,
        speechPadding: 0.1
    )

    private let speculativeIntervalSamples = Int(2.0 * 16000)
    private let speculativeMinSpeechSamples = Int(1.0 * 16000)

    private var decayTimer: Timer?

    private init() {
        let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            Task { @MainActor in
                await TranscriptionEngine.shared.feed(buffer)
            }
        }
        self.capture = AudioCapture(bufferHandler: bufferHandler)
        // 30Hz decay tick. Cheap; only mutates levels when something changed.
        self.decayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isActive { self.decayLevels() }
            }
        }
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

    var isRecording: Bool { isActive }

    func preload() {
        Task { @MainActor in
            do {
                _ = try await ensureLoaded()
                if !isActive, !isStarting {
                    status = .idle
                }
            } catch {
                log.error("Preload failed: \(error.localizedDescription)")
            }
        }
    }

    private func start() async {
        guard !isActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        autoHideTask?.cancel()
        confirmedText = ""
        volatileText = ""
        lastSpeculativeSampleCount = 0
        liveTranscript = ""

        do {
            try await ensureMicPermission()
            let (_, vad) = try await ensureLoaded()

            sessionSamples.removeAll(keepingCapacity: true)
            vadPending.removeAll(keepingCapacity: true)
            vadState = await vad.makeStreamState()
            currentSpeechStart = nil

            status = .listening
            try capture.start()
            isActive = true
        } catch {
            log.error("Start failed: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
            scheduleAutoHide(after: 2.5)
        }
    }

    private func stop() async {
        guard isActive else { return }
        isActive = false
        capture.stop()
        status = .finishing

        if let start = currentSpeechStart, start < sessionSamples.count {
            let tail = Array(sessionSamples[start..<sessionSamples.count])
            currentSpeechStart = nil
            enqueueTranscribe(samples: tail)
        }
        await transcribeChain?.value

        let finalText = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = finalText

        if !finalText.isEmpty {
            UIPasteboard.general.string = finalText
            history.add(finalText)
            status = .copied
            scheduleAutoHide(after: 1.5)
        } else {
            status = .idle
            scheduleAutoHide(after: 1.0)
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard isActive else { return }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleBuffer(buffer)
        } catch {
            log.error("Resample failed: \(error.localizedDescription)")
            return
        }

        sessionSamples.append(contentsOf: samples)
        pushLevel(from: samples)

        guard let vad = vadManager, var currentVadState = vadState else { return }
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
                lastSpeculativeSampleCount = event.sampleIndex
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

        maybeRunSpeculative()
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

    private func maybeRunSpeculative() {
        guard let start = currentSpeechStart else { return }
        let total = sessionSamples.count
        guard total - lastSpeculativeSampleCount >= speculativeIntervalSamples else { return }
        guard total - start >= speculativeMinSpeechSamples else { return }

        lastSpeculativeSampleCount = total
        let segment = Array(sessionSamples[start..<total])
        let segmentStart = start
        enqueueSpeculative(samples: segment, segmentStart: segmentStart)
    }

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
            let cleaned = Self.cleanTranscript(result.text)
            await MainActor.run {
                if !cleaned.isEmpty {
                    if self.confirmedText.isEmpty {
                        self.confirmedText = cleaned
                    } else {
                        self.confirmedText += " " + cleaned
                    }
                }
                self.volatileText = ""
                self.liveTranscript = self.displayText()
            }
        } catch {
            log.error("Transcribe failed: \(error.localizedDescription)")
        }
    }

    private func enqueueSpeculative(samples: [Float], segmentStart: Int) {
        let previous = transcribeChain
        transcribeChain = Task { [weak self] in
            await previous?.value
            await self?.performSpeculative(samples: samples, segmentStart: segmentStart)
        }
    }

    private func performSpeculative(samples: [Float], segmentStart: Int) async {
        guard currentSpeechStart == segmentStart, isActive else { return }
        guard let asr = asrManager else { return }
        do {
            let result = try await asr.transcribe(samples, source: .microphone)
            let cleaned = Self.cleanTranscript(result.text)
            await MainActor.run {
                guard self.isActive, self.currentSpeechStart == segmentStart else { return }
                self.volatileText = cleaned
                self.liveTranscript = self.displayText()
            }
        } catch {
            log.error("Speculative transcribe failed: \(error.localizedDescription)")
        }
    }

    private static let fillerWordRegex: NSRegularExpression = {
        let pattern = #"(?i)\b(?:u+h+m*|u+m+h*|e+r+h*|a+h+m*|hmm+|mm+|mhm+)\b[,\.]?\s*"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func cleanTranscript(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        var text = fillerWordRegex.stringByReplacingMatches(
            in: raw, options: [], range: range, withTemplate: ""
        )
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, ",.;:!?".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func displayText() -> String {
        switch (confirmedText.isEmpty, volatileText.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return confirmedText
        case (true, false):  return volatileText
        case (false, false): return confirmedText + " " + volatileText
        }
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

    private func ensureLoaded() async throws -> (AsrManager, VadManager) {
        if let asr = asrManager, let vad = vadManager { return (asr, vad) }
        if let existing = loadingTask { return try await existing.value }

        status = .preparing("Loading speech model…")

        let task = Task<(AsrManager, VadManager), Error> { @MainActor in
            let mlConfig = MLModelConfiguration()
            // iPhone's Neural Engine is the right home for Parakeet — the
            // sandbox/cache concerns that pushed the Mac build to .cpuAndGPU
            // don't apply on iOS.
            mlConfig.computeUnits = .cpuAndNeuralEngine

            guard let modelDir = Self.bundledASRDir() else {
                throw TranscriptionError.modelsMissing
            }

            log.info("Loading ASR from \(modelDir.path, privacy: .public)")
            let asrModels = try await AsrModels.load(
                from: modelDir,
                configuration: mlConfig,
                version: .v3
            )
            let asr = AsrManager(config: .default)
            try await asr.loadModels(asrModels)

            status = .preparing("Loading voice detector…")
            let vadConfig = VadConfig(computeUnits: .cpuAndNeuralEngine)
            guard let vadBase = Self.bundledVADBaseURL() else {
                throw TranscriptionError.modelsMissing
            }
            let vad = try await VadManager(config: vadConfig, modelDirectory: vadBase)

            status = .preparing("Warming up…")
            await Self.warmUp(asr: asr, vad: vad)
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

    private static let asrSubpath = "Models/parakeet-tdt-0.6b-v3"
    private static let vadModelFile = "silero-vad-unified-256ms-v6.0.0.mlmodelc"
    private static let requiredASRFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    private static func bundledASRDir() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent(asrSubpath, isDirectory: true)
        let fm = FileManager.default
        for f in requiredASRFiles where !fm.fileExists(atPath: dir.appendingPathComponent(f).path) {
            return nil
        }
        return dir
    }

    private static func bundledVADBaseURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let modelPath = resources
            .appendingPathComponent("Models/silero-vad", isDirectory: true)
            .appendingPathComponent(vadModelFile, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return nil }
        return resources
    }

    private static func warmUp(asr: AsrManager, vad: VadManager) async {
        do {
            let oneSecondOfSilence = [Float](repeating: 0.0, count: 16_000)
            _ = try await asr.transcribe(oneSecondOfSilence, source: .microphone)
        } catch {
            log.info("ASR warmup skipped: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let chunk = [Float](repeating: 0.0, count: VadManager.chunkSize)
            let state = await vad.makeStreamState()
            _ = try await vad.processStreamingChunk(chunk, state: state)
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
            if !isActive {
                status = .idle
                liveTranscript = ""
            }
        }
    }
}
#endif
