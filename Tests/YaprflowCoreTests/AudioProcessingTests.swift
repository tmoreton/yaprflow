import AVFoundation
import CoreML
import Foundation
import Testing
@testable import YaprflowCore

@Suite("Shared audio processing", .serialized)
struct AudioProcessingTests {
    @MainActor
    @Test("Stateful converter preserves a one-second stream across buffer boundaries")
    func streamingConversion() throws {
        let sourceRate = 48_000.0
        let framesPerBuffer = 480
        let converter = StreamingAudioConverter()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ) else {
            Issue.record("Could not create the source audio format")
            return
        }

        var converted: [Float] = []
        for bufferIndex in 0..<100 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesPerBuffer)
            ), let channel = buffer.floatChannelData?[0] else {
                Issue.record("Could not create a source audio buffer")
                return
            }
            buffer.frameLength = AVAudioFrameCount(framesPerBuffer)
            for frame in 0..<framesPerBuffer {
                let sample = bufferIndex * framesPerBuffer + frame
                channel[frame] = sin(2 * .pi * 440 * Float(sample) / Float(sourceRate))
            }
            converted.append(contentsOf: try converter.resampleBuffer(buffer))
        }

        #expect(abs(converted.count - 16_000) <= 256)
        #expect(converted.contains(where: { abs($0) > 0.1 }))
    }

    @Test("Bundled voice detector accepts its production model")
    func bundledVoiceDetectorSmokeTest() async throws {
        let modelURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(BundledModelInventory.voiceDetectorDirectory)
            .appendingPathComponent(BundledModelInventory.voiceDetectorModel)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return
        }

        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = .cpuOnly
        let model = try MLModel(
            contentsOf: modelURL,
            configuration: modelConfiguration
        )
        let detector = VoiceActivityDetector(model: model)
        let state = await detector.makeStreamState()
        let result = try await detector.processStreamingChunk(
            [Float](repeating: 0, count: VoiceActivityDetector.chunkSize),
            state: state,
            configuration: .init()
        )

        #expect(result.event?.sampleIndex == nil)
    }
}
