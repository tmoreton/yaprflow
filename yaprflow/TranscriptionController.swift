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

@MainActor
final class TranscriptionController {
    static let shared = TranscriptionController()

    private let state = AppState.shared
    private let capture: AudioCapture
    private let audioConverter = AudioConverter()
    private let memoryPressureSource: DispatchSourceMemoryPressure

    // Models stay warm between nearby recordings, then unload while idle so
    // the ~1.8 GB Core ML allocation cannot make macOS kill the menu-bar app
    // later under memory pressure.
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var loadingTask: Task<(AsrManager, VadManager), Error>?
    private var modelUnloadTask: Task<Void, Never>?

    // Per-session state
    private var sessionSamples: [Float] = []
    private var vadPending: [Float] = []
    private var vadState: VadStreamState?
    private var currentSpeechStart: Int?
    private var confirmedText = ""
    private var volatileText = ""
    private var vocabularyReplacementCount = 0
    private var sessionSourceApplication: String?
    private var lastSpeculativeSampleCount = 0
    private var transcribeChain: Task<Void, Never>?

    private var isActive = false
    private var isStarting = false
    private var autoHideTask: Task<Void, Never>?

    // Long maxSpeechDuration (60s) for continuous dictation without forced chunks.
    // Silence-based segmentation handles natural pauses.
    private let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.3,
        maxSpeechDuration: 60.0,
        speechPadding: 0.1
    )

    // Speculative partials: re-transcribe in-progress speech every 2.0s.
    // Less frequent = fewer re-transcriptions for long recordings.
    private let speculativeIntervalSamples = Int(2.0 * 16000)
    private let speculativeMinSpeechSamples = Int(1.0 * 16000)

    private init() {
        let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            Task { @MainActor in
                await TranscriptionController.shared.feed(buffer)
            }
        }
        self.capture = AudioCapture(bufferHandler: bufferHandler)

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
        log.info("Recording toggle requested (active: \(self.isActive, privacy: .public), starting: \(self.isStarting, privacy: .public))")
        Task { @MainActor in
            if isActive {
                await stop()
            } else {
                await start()
            }
        }
    }

    func runRecordingSmokeTest(
        startAction: (@MainActor () -> Void)? = nil,
        stopAction: (@MainActor () -> Void)? = nil
    ) async -> RecordingSmokeTestResult {
        guard !isActive, !isStarting else {
            return RecordingSmokeTestResult(
                succeeded: false,
                message: "A recording was already active."
            )
        }

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
            try await Task.sleep(for: .seconds(2))
        } catch {
            return RecordingSmokeTestResult(succeeded: false, message: "The recording test was interrupted.")
        }

        if let stopAction {
            stopAction()
            await waitForRecordingToStop()
        } else {
            await stop()
        }
        return RecordingSmokeTestResult(
            succeeded: !isActive,
            message: "The Transcribe menu action and microphone capture engine started and stopped successfully."
        )
    }

    private func waitForRecordingToStart() async {
        for _ in 0..<1_200 {
            if isActive || isErrorStatus { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForRecordingToStop() async {
        for _ in 0..<1_200 {
            if !isActive, !isStarting, state.status != .finishing { return }
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
        case .finishing: return "finishing"
        case .copied: return "copied"
        case let .error(message): return message
        }
    }

    private func start() async {
        guard !isActive, !isStarting else { return }
        log.info("Starting recording pipeline")
        isStarting = true
        defer { isStarting = false }

        autoHideTask?.cancel()
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        confirmedText = ""
        volatileText = ""
        vocabularyReplacementCount = 0
        sessionSourceApplication = Self.frontmostApplicationName()
        lastSpeculativeSampleCount = 0
        state.liveTranscript = ""
        NotchOverlayWindowController.shared.show()

        do {
            state.status = .preparing("Checking microphone access…")
            try await ensureMicPermission()
            try capture.validateInputAvailable()
            let (_, vad) = try await ensureLoaded()

            sessionSamples.removeAll(keepingCapacity: true)
            vadPending.removeAll(keepingCapacity: true)
            vadState = await vad.makeStreamState()
            currentSpeechStart = nil

            state.status = .listening
            try capture.start()
            isActive = true
            log.info("Microphone capture started")
        } catch {
            log.error("Start failed: \(error.localizedDescription)")
            state.status = .error(error.localizedDescription)
            NotchOverlayWindowController.shared.show(force: true)
            scheduleAutoHide(after: 2.5)
            scheduleModelUnload()
        }
    }

    private func stop() async {
        guard isActive else { return }
        isActive = false
        capture.stop()
        state.status = .finishing

        // Flush any pending speech segment so we don't lose the tail of what
        // the user was saying.
        if let start = currentSpeechStart, start < sessionSamples.count {
            let tail = Array(sessionSamples[start..<sessionSamples.count])
            currentSpeechStart = nil
            enqueueTranscribe(samples: tail)
        }
        await transcribeChain?.value
        transcribeChain = nil

        let finalText = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.liveTranscript = finalText

        if !finalText.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(finalText, forType: .string)
            state.recordTranscript(
                finalText,
                sourceApplication: sessionSourceApplication,
                vocabularyReplacementCount: vocabularyReplacementCount
            )
            state.status = .copied
            scheduleAutoHide(after: 1.2)
        } else {
            state.status = .idle
            scheduleAutoHide(after: 1.2)
        }
        scheduleModelUnload()
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

    /// While the user is still speaking, re-transcribe the in-progress speech
    /// segment every ~2s and show it as volatile text. The confirmed segment
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
            let processed = state.processTranscript(result.text)
            await MainActor.run {
                if !processed.text.isEmpty {
                    if self.confirmedText.isEmpty {
                        self.confirmedText = processed.text
                    } else {
                        self.confirmedText += " " + processed.text
                    }
                    self.vocabularyReplacementCount += processed.vocabularyReplacementCount
                }
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
        guard currentSpeechStart == segmentStart, isActive else { return }
        guard let asr = asrManager else { return }
        do {
            let result = try await asr.transcribe(samples, source: .microphone)
            let processed = state.processTranscript(result.text)
            await MainActor.run {
                guard self.isActive, self.currentSpeechStart == segmentStart else { return }
                self.volatileText = processed.text
                self.state.liveTranscript = self.displayText()
            }
        } catch {
            log.error("Speculative transcribe failed: \(error.localizedDescription)")
        }
    }

    private func displayText() -> String {
        switch (confirmedText.isEmpty, volatileText.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return confirmedText
        case (true, false):  return volatileText
        case (false, false): return confirmedText + " " + volatileText
        }
    }

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

    private func ensureLoaded() async throws -> (AsrManager, VadManager) {
        if let asr = asrManager, let vad = vadManager { return (asr, vad) }
        if let existing = loadingTask {
            return try await existing.value
        }

        state.status = .preparing("Loading transcription model…")

        let task = Task<(AsrManager, VadManager), Error> { @MainActor in
            let mlConfig = MLModelConfiguration()
            // .cpuAndGPU instead of .cpuAndNeuralEngine: ANE forces a heavy
            // AOT compile (~30s, ~2GB of disk writes) on every launch when the
            // app is sandboxed, because the e5 bundle cache doesn't survive
            // in the container's Caches dir. That tripped macOS disk-write
            // throttling and Jetsam (silent kills).
            mlConfig.computeUnits = .cpuAndGPU

            let modelDir = try await self.ensureModelsLocally()

            state.status = .preparing("Preparing speech model for your Mac…")
            log.info("Loading ASR model from \(modelDir.path, privacy: .public)")

            let asrModels: AsrModels
            do {
                asrModels = try await AsrModels.load(
                    from: modelDir,
                    configuration: mlConfig,
                    version: .v3
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
                    version: .v3
                )
            }

            let asr = AsrManager(config: .default)
            try await asr.loadModels(asrModels)

            state.status = .preparing("Loading voice detector…")
            // Silero VAD is tiny and runs comfortably on CPU. Asking Core ML
            // to prepare a GPU plan for it can stall first recording startup
            // for more than a minute on some Macs.
            let vadConfig = VadConfig(computeUnits: .cpuOnly)
            let vad: VadManager
            if let vadBase = Self.bundledVADBaseURL() {
                log.info("Loading bundled VAD from \(vadBase.path, privacy: .public)")
                vad = try await VadManager(config: vadConfig, modelDirectory: vadBase)
            } else {
                log.info("Bundled VAD missing, downloading Silero VAD from HuggingFace")
                vad = try await VadManager(config: vadConfig)
            }

            return (asr, vad)
        }
        loadingTask = task

        do {
            let (asr, vad) = try await task.value
            loadingTask = nil
            self.asrManager = asr
            self.vadManager = vad
            return (asr, vad)
        } catch {
            loadingTask = nil
            throw error
        }
    }

    private static let modelSubpath = "Models/parakeet-tdt-0.6b-v3"
    private static let requiredModelFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    /// Small model pieces that ship inside the app bundle. The big
    /// `Encoder.mlmodelc` is downloaded on first launch so the DMG stays small.
    private static let bundledSmallModelFiles = [
        "Preprocessor.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    private static let encoderDownloadURL = URL(string:
        "https://github.com/tmoreton/yaprflow/releases/download/models-v3/parakeet-v3-encoder.tar.gz"
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
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
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
        // extraction, corrupt bytes — wipe and start over. Re-downloading is
        // slower than shipping with a broken model.
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            log.info("Cache at \(cacheDir.path, privacy: .public) is incomplete; clearing before re-populating.")
            try? FileManager.default.removeItem(at: cacheDir)
        }

        try await populateModelCache(cacheDir)

        guard Self.cacheLooksHealthy(cacheDir) else {
            try? FileManager.default.removeItem(at: cacheDir)
            throw NSError(domain: "yaprflow.model", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Model files look incomplete after download. Please try again — if it keeps failing, your network may be blocking GitHub releases."
            ])
        }
        return cacheDir
    }

    /// A "healthy" cache has all required files AND the encoder's weight file
    /// is at least 100 MB. Catches partial extractions where the directory
    /// exists but its contents are truncated.
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

        for name in Self.bundledSmallModelFiles {
            let src = partial.appendingPathComponent(name)
            let dst = cacheDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            try fm.copyItem(at: src, to: dst)
        }

        if !fm.fileExists(atPath: cacheDir.appendingPathComponent("Encoder.mlmodelc").path) {
            try await downloadAndExtractEncoder(into: cacheDir)
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
        // ensures a crashed/killed extract can never leave a half-written
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

    private func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15 * 60))
            } catch {
                return
            }
            self?.releaseModelsIfIdle(reason: "15 minutes idle")
        }
    }

    private func releaseModelsIfIdle(reason: String) {
        guard !isActive,
              !isStarting,
              loadingTask == nil,
              transcribeChain == nil
        else {
            return
        }
        guard asrManager != nil || vadManager != nil else { return }

        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        asrManager = nil
        vadManager = nil
        vadState = nil
        sessionSamples.removeAll(keepingCapacity: false)
        vadPending.removeAll(keepingCapacity: false)
        log.info("Released transcription models after \(reason, privacy: .public)")
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
