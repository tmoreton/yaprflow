import AVFoundation

nonisolated final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false
    private let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void

    init(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.bufferHandler = bufferHandler
    }

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

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
