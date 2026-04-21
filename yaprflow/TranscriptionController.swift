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
    private var manager: StreamingEouAsrManager?
    private var isActive = false
    private var autoHideTask: Task<Void, Never>?

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
        guard !isActive else { return }
        autoHideTask?.cancel()
        state.liveTranscript = ""

        NotchOverlayWindowController.shared.show()

        do {
            try await ensureMicPermission()
            try await ensureModelLoaded()
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

        do {
            let finalText = try await manager?.finish() ?? ""
            state.liveTranscript = finalText
            await manager?.reset()

            if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(finalText, forType: .string)
                state.status = .copied
            } else {
                state.status = .idle
            }
            scheduleAutoHide(after: 1.2)
        } catch {
            log.error("Finish failed: \(error.localizedDescription)")
            state.status = .error(error.localizedDescription)
            scheduleAutoHide(after: 2.5)
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard isActive, let manager else { return }
        do {
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            log.error("ASR process error: \(error.localizedDescription)")
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

    private func ensureModelLoaded() async throws {
        if manager != nil { return }

        state.status = .preparing("Loading transcription model…")

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let m = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms160,
            eouDebounceMs: 1280
        )

        await m.setPartialCallback { partial in
            Task { @MainActor in
                AppState.shared.liveTranscript = partial
            }
        }

        if let bundled = Self.bundledModelURL() {
            log.info("Loading bundled model from \(bundled.path, privacy: .public)")
            try await m.loadModels(modelDir: bundled)
        } else {
            log.info("Bundled model missing, downloading from HuggingFace")
            state.status = .preparing("Downloading model…")
            try await m.loadModelsFromHuggingFace(
                progressHandler: { progress in
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    Task { @MainActor in
                        AppState.shared.status = .preparing("Downloading model… \(pct)%")
                    }
                }
            )
        }

        self.manager = m
    }

    private static let modelSubpath = "Models/parakeet-realtime-eou-120m-coreml/160ms"
    private static let requiredModelFiles = [
        "streaming_encoder.mlmodelc",
        "decoder.mlmodelc",
        "joint_decision.mlmodelc",
        "vocab.json",
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
