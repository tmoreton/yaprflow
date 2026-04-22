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
    private var volatileText = ""
    private var lastSpeculativeSampleCount = 0
    private var transcribeChain: Task<Void, Never>?

    private var isActive = false
    private var isStarting = false
    private var autoHideTask: Task<Void, Never>?

    // Tighter than SDK default (0.75s) so dictation feels snappy.
    private let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.3,
        maxSpeechDuration: 12.0,
        speechPadding: 0.1
    )

    // Speculative partials: while the user is still speaking, re-transcribe the
    // in-progress segment every N seconds and show as volatile text.
    private let speculativeIntervalSamples = Int(1.2 * 16000)
    private let speculativeMinSpeechSamples = Int(0.6 * 16000)

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

    /// Eagerly load ASR + VAD models so the first hotkey press doesn't block
    /// on the ~30s Encoder compile. Safe to call multiple times — subsequent
    /// calls are no-ops once the models are loaded.
    func preload() {
        Task { @MainActor in
            do {
                _ = try await ensureLoaded()
                // Don't leave the overlay/menu showing a stale "preparing…"
                // status once preload finishes if the user hasn't started yet.
                if !isActive, !isStarting {
                    state.status = .idle
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

    /// While the user is still speaking, re-transcribe the in-progress speech
    /// segment every ~1.2s and show it as volatile text. The confirmed segment
    /// replaces this on speechEnd.
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
            let cleaned = Self.cleanTranscript(result.text)
            await MainActor.run {
                if !cleaned.isEmpty {
                    if self.confirmedText.isEmpty {
                        self.confirmedText = cleaned
                    } else {
                        self.confirmedText += " " + cleaned
                    }
                }
                // This segment is confirmed — drop any volatile text that was
                // showing a preview of it.
                self.volatileText = ""
                self.state.liveTranscript = self.displayText()
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
        // Skip if the user already paused (speechEnd fired) — the confirmed
        // transcribe is about to run and supersede this anyway.
        guard currentSpeechStart == segmentStart, isActive else { return }
        guard let asr = asrManager else { return }
        do {
            let result = try await asr.transcribe(samples, source: .microphone)
            let cleaned = Self.cleanTranscript(result.text)
            await MainActor.run {
                // Re-check relevance: the segment may have ended or a new one
                // started by the time the transcribe returned.
                guard self.isActive, self.currentSpeechStart == segmentStart else { return }
                self.volatileText = cleaned
                self.state.liveTranscript = self.displayText()
            }
        } catch {
            log.error("Speculative transcribe failed: \(error.localizedDescription)")
        }
    }

    /// Regex matching filler words ("uh", "um", "er", "ah", "hmm", "mm"
    /// and obvious repetitions like "uhhh") as standalone words — not
    /// substrings — so we don't eat real tokens like "umbrella" or "ermine".
    /// Optional trailing comma or period gets swallowed with the filler.
    private static let fillerWordRegex: NSRegularExpression = {
        let pattern = #"(?i)\b(?:u+h+m*|u+m+h*|e+r+h*|a+h+m*|hmm+|mm+|mhm+)\b[,\.]?\s*"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func cleanTranscript(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        var text = fillerWordRegex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: range,
            withTemplate: ""
        )
        // Tidy up double spaces and stranded leading punctuation the model may
        // leave behind (e.g. "um, hello" → ", hello" → "hello").
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

            let modelDir = try await self.ensureModelsLocally()

            state.status = .preparing("Preparing speech model for your Mac…")
            log.info("Loading ASR model from \(modelDir.path, privacy: .public)")

            let asrModels: AsrModels
            do {
                asrModels = try await AsrModels.load(
                    from: modelDir,
                    configuration: mlConfig,
                    version: .v2
                )
            } catch {
                // A freshly-downloaded model that fails to load is almost
                // always bytes on disk that CoreML can't parse — wipe and
                // retry once before giving up.
                log.error("Initial model load failed (\(error.localizedDescription)); clearing cache and retrying.")
                try? FileManager.default.removeItem(at: Self.cachedModelDir())
                let freshModelDir = try await self.ensureModelsLocally()
                asrModels = try await AsrModels.load(
                    from: freshModelDir,
                    configuration: mlConfig,
                    version: .v2
                )
            }

            let asr = AsrManager(config: .default)
            try await asr.loadModels(asrModels)

            state.status = .preparing("Loading voice detector…")
            let vadConfig = VadConfig(computeUnits: .cpuAndNeuralEngine)
            let vad: VadManager
            if let vadBase = Self.bundledVADBaseURL() {
                log.info("Loading bundled VAD from \(vadBase.path, privacy: .public)")
                vad = try await VadManager(config: vadConfig, modelDirectory: vadBase)
            } else {
                log.info("Bundled VAD missing, downloading Silero VAD from HuggingFace")
                vad = try await VadManager(config: vadConfig)
            }

            // Warm up first-inference compile paths. Without this, the user's
            // first real transcribe on a fresh install pays a 5–10s CoreML
            // warmup cost and feels broken. One silent chunk each is enough.
            state.status = .preparing("Warming up…")
            log.info("Warming up ASR + VAD with silent chunks")
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

    private static let modelSubpath = "Models/parakeet-tdt-0.6b-v2"
    private static let requiredModelFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    /// Small model pieces that ship inside the app bundle. The big
    /// `Encoder.mlmodelc` (~445MB) is downloaded on first launch so the DMG
    /// stays small.
    private static let bundledSmallModelFiles = [
        "Preprocessor.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    private static let encoderDownloadURL = URL(string:
        "https://github.com/tmoreton/yaprflow/releases/download/models-v2/parakeet-v2-encoder.tar.gz"
    )!

    /// Full bundle (dev builds with the encoder still in the repo). If every
    /// file is in the bundle, we use it directly.
    private static func fullBundledModelDir() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent(modelSubpath, isDirectory: true)
        return allModelFilesPresent(in: dir) ? dir : nil
    }

    /// Production bundle (encoder stripped). Returns the bundle dir if the
    /// small files are present — they'll be copied into the writable cache.
    private static func partialBundledModelDir() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent(modelSubpath, isDirectory: true)
        let fm = FileManager.default
        for file in bundledSmallModelFiles where !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return nil
        }
        return dir
    }

    /// Writable cache location that `AsrModels.load` reads from. In a
    /// sandboxed app this resolves under the app's container.
    private static func cachedModelDir() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
    }

    private static func allModelFilesPresent(in dir: URL) -> Bool {
        let fm = FileManager.default
        for file in requiredModelFiles where !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return false
        }
        return true
    }

    private func ensureModelsLocally() async throws -> URL {
        // Dev builds with the encoder still in the repo.
        if let bundle = Self.fullBundledModelDir() {
            return bundle
        }

        // Cache already populated from a previous launch and looks healthy.
        let cacheDir = Self.cachedModelDir()
        if Self.cacheLooksHealthy(cacheDir) {
            return cacheDir
        }

        // Anything less than a healthy cache — partial download, partial
        // extraction, corrupt bytes — wipe and start over. Re-downloading 400MB
        // is slower than shipping with a broken model.
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            log.info("Cache at \(cacheDir.path, privacy: .public) is incomplete; clearing before re-populating.")
            try? FileManager.default.removeItem(at: cacheDir)
        }

        try await populateModelCache(cacheDir)

        guard Self.cacheLooksHealthy(cacheDir) else {
            // Populate succeeded but the files still don't look right — fail
            // loudly rather than load a broken model.
            try? FileManager.default.removeItem(at: cacheDir)
            throw NSError(domain: "yaprflow.model", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Model files look incomplete after download. Please try again — if it keeps failing, your network may be blocking GitHub releases."
            ])
        }
        return cacheDir
    }

    /// A "healthy" cache has all required files AND the encoder's weight file
    /// is at least 100 MB (uncompressed encoder weights are ~400 MB). This
    /// catches partial extractions where the directory exists but its contents
    /// are truncated.
    private static func cacheLooksHealthy(_ dir: URL) -> Bool {
        guard allModelFilesPresent(in: dir) else { return false }
        let weightFile = dir
            .appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
            .appendingPathComponent("weights", isDirectory: true)
            .appendingPathComponent("weight.bin")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: weightFile.path),
              let size = attrs[.size] as? Int64,
              size > 100_000_000
        else {
            return false
        }
        return true
    }

    private func populateModelCache(_ cacheDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        guard let partial = Self.partialBundledModelDir() else {
            throw NSError(domain: "yaprflow.model", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Bundled model files missing — please reinstall Yaprflow."
            ])
        }

        // Copy small pieces from bundle → cache (only ones not already present).
        for name in Self.bundledSmallModelFiles {
            let src = partial.appendingPathComponent(name)
            let dst = cacheDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            if src.hasDirectoryPath {
                try fm.copyItem(at: src, to: dst)
            } else {
                try fm.copyItem(at: src, to: dst)
            }
        }

        // Download + extract Encoder if not already there.
        if !fm.fileExists(atPath: cacheDir.appendingPathComponent("Encoder.mlmodelc").path) {
            try await downloadAndExtractEncoder(into: cacheDir)
        }
    }

    /// Run a silent chunk through both models so CoreML's per-device
    /// compile + first-inference warmup happens during preload, not on the
    /// user's first real dictation. Any error here is swallowed — the worst
    /// case is the original slow-first-call behaviour.
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

    private func downloadAndExtractEncoder(into cacheDir: URL) async throws {
        state.status = .preparing("Downloading speech model... 0%")
        log.info("Downloading encoder from \(Self.encoderDownloadURL.absoluteString, privacy: .public)")

        let delegate = EncoderDownloadDelegate()
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: Self.encoderDownloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: "yaprflow.download", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))"
            ])
        }

        state.status = .preparing("Extracting speech model...")

        // Extract into a staging sibling directory first; only move into the
        // real cache if tar succeeds AND the expected files are there. This
        // way a crashed/killed extract can never leave a half-written
        // Encoder.mlmodelc that fools cacheLooksHealthy on the next launch.
        let fm = FileManager.default
        let stagingDir = cacheDir
            .deletingLastPathComponent()
            .appendingPathComponent(".encoder-staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        log.info("Extracting encoder into staging \(stagingDir.path, privacy: .public)")

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tempURL.path, "-C", stagingDir.path]
        let errPipe = Pipe()
        tar.standardError = errPipe

        try tar.run()
        tar.waitUntilExit()

        try? fm.removeItem(at: tempURL)

        guard tar.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "yaprflow.extract", code: Int(tar.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Extract failed (exit \(tar.terminationStatus)): \(errStr)"
            ])
        }

        // Verify the encoder extracted correctly before promoting.
        let extractedEncoder = stagingDir.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        let extractedWeight = extractedEncoder
            .appendingPathComponent("weights", isDirectory: true)
            .appendingPathComponent("weight.bin")
        guard fm.fileExists(atPath: extractedEncoder.path),
              let attrs = try? fm.attributesOfItem(atPath: extractedWeight.path),
              let size = attrs[.size] as? Int64,
              size > 100_000_000
        else {
            throw NSError(domain: "yaprflow.extract", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Extracted encoder looks incomplete — weight file missing or truncated. Try again."
            ])
        }

        // Atomic-ish promote. Same filesystem, rename is atomic.
        let finalEncoder = cacheDir.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        try? fm.removeItem(at: finalEncoder)
        try fm.moveItem(at: extractedEncoder, to: finalEncoder)
    }

    private static let vadModelFile = "silero-vad-unified-256ms-v6.0.0.mlmodelc"

    /// Returns the base directory that `VadManager(modelDirectory:)` expects —
    /// it internally appends `Models/silero-vad/<file>`. We bundle the model at
    /// `<Resources>/Models/silero-vad/...`, so `Resources` is the right base.
    private static func bundledVADBaseURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let modelPath = resources
            .appendingPathComponent("Models/silero-vad", isDirectory: true)
            .appendingPathComponent(vadModelFile, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return nil }
        return resources
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

/// URLSession delegate that pushes download progress into AppState.status so
/// the overlay shows "Downloading speech model... 42%" during first launch.
private final class EncoderDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let pct = Int((fraction * 100).rounded())
        Task { @MainActor in
            AppState.shared.status = .preparing("Downloading speech model... \(pct)%")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Intentionally empty — URLSession's async `download(from:)` moves the
        // file to a temp location and returns its URL from the awaited call.
    }
}
