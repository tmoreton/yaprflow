import AVFoundation
import AppKit
import CoreML
import FluidAudio
import Foundation

@MainActor
final class TranscriptionController {
    static let shared = TranscriptionController()

    private let state = AppState.shared
    private var capture: AudioCapture?
    private var manager: StreamingEouAsrManager?
    private var isModelLoaded = false
    private var isActive = false
    private var autoHideTask: Task<Void, Never>?

    private init() {
        capture = AudioCapture { [weak self] buffer in
            Task { @MainActor in
                await self?.feed(buffer)
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

    private func start() async {
        guard !isActive else { return }
        autoHideTask?.cancel()
        state.liveTranscript = ""

        NotchOverlayWindowController.shared.show()

        do {
            try await ensureMicPermission()
        } catch {
            state.status = .error("Microphone access denied")
            scheduleAutoHide(after: 2.5)
            return
        }

        do {
            try await ensureModelLoaded()
        } catch {
            state.status = .error("Model load failed: \(error.localizedDescription)")
            scheduleAutoHide(after: 3.0)
            return
        }

        do {
            state.status = .listening
            try capture?.start()
            isActive = true
        } catch {
            state.status = .error("Mic error: \(error.localizedDescription)")
            scheduleAutoHide(after: 2.5)
        }
    }

    private func stop() async {
        guard isActive else { return }
        isActive = false
        capture?.stop()
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
            state.status = .error(error.localizedDescription)
            scheduleAutoHide(after: 2.5)
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard isActive, let manager else { return }
        do {
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            NSLog("ASR process error: \(error)")
        }
    }

    private func ensureMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw NSError(domain: "Yaprflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
            }
        case .denied, .restricted:
            throw NSError(domain: "Yaprflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        @unknown default:
            throw NSError(domain: "Yaprflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access unknown"])
        }
    }

    private func ensureModelLoaded() async throws {
        if isModelLoaded, manager != nil { return }

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

        try await m.loadModelsFromHuggingFace(
            progressHandler: { progress in
                let pct = Int((progress.fractionCompleted * 100).rounded())
                Task { @MainActor in
                    AppState.shared.status = .preparing("Downloading model… \(pct)%")
                }
            }
        )

        self.manager = m
        self.isModelLoaded = true
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            state.status = .idle
            state.liveTranscript = ""
            NotchOverlayWindowController.shared.hide()
        }
    }
}
