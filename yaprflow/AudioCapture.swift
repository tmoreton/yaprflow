@preconcurrency import AVFoundation

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is connected. Connect or select one in System Settings → Sound → Input."
        case .invalidInputFormat:
            return "The selected microphone is unavailable. Choose another input in System Settings → Sound → Input."
        }
    }
}

nonisolated final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false
    private let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void

    init(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.bufferHandler = bufferHandler
    }

    func validateInputAvailable() throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioCaptureError.noInputDevice
        }
    }

    func start() throws {
        guard !running else { return }
        try validateInputAvailable()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [handler = bufferHandler] buffer, _ in
            guard let copy = AudioCapture.copy(buffer: buffer) else { return }
            handler(copy)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)
        else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        }
        return copy
    }
}
