import AVFoundation
import CoreML
import Foundation
import Testing
@testable import YaprflowCore

@Suite("Shared audio processing", .serialized)
struct AudioProcessingTests {
    @Test("Audio meter maps silence and speech into a bounded display level")
    func audioLevelMeter() {
        let silence = AudioLevelMeter.normalizedLevel(for: [Float](repeating: 0, count: 512))
        let quiet = AudioLevelMeter.normalizedLevel(for: [Float](repeating: 0.002, count: 512))
        let speech = AudioLevelMeter.normalizedLevel(for: [Float](repeating: 0.2, count: 512))
        let clipped = AudioLevelMeter.normalizedLevel(for: [Float](repeating: 2, count: 512))

        #expect(silence == 0)
        #expect(quiet > silence)
        #expect(speech > quiet)
        #expect(clipped == 1)
    }

    @Test("Offline recognition pads brief speech to Parakeet's one-second minimum")
    func shortRecognitionPadding() {
        let short = [Float](repeating: 0.25, count: 4_800)
        let padded = OfflineRecognitionAudio.paddedToMinimumDuration(short)
        let alreadyLong = [Float](repeating: 0.25, count: 20_000)

        #expect(padded.count == 16_000)
        #expect(Array(padded.prefix(short.count)) == short)
        #expect(padded.dropFirst(short.count).allSatisfy { $0 == 0 })
        #expect(OfflineRecognitionAudio.paddedToMinimumDuration(alreadyLong) == alreadyLong)
    }

    @Test("VAD boundaries retain independent onset and trailing context")
    func voiceBoundaryPadding() {
        let chunkSize = 4_096
        let configuration = VoiceActivitySegmentationConfiguration(
            minSilenceDuration: 0.6,
            speechStartPadding: 0.35,
            speechEndPadding: 0.45
        )
        var state = VoiceActivityStreamState()

        var result = VoiceActivityBoundaryDetector.process(
            probability: 0,
            chunkSampleCount: chunkSize,
            state: state,
            configuration: configuration,
            entryThreshold: 0.85,
            exitThreshold: 0.7
        )
        state = result.state
        result = VoiceActivityBoundaryDetector.process(
            probability: 0.95,
            chunkSampleCount: chunkSize,
            state: state,
            configuration: configuration,
            entryThreshold: 0.85,
            exitThreshold: 0.7
        )
        state = result.state

        #expect(result.event?.sampleIndex == 0)
        if case .speechStart? = result.event?.kind {
            // Expected start event.
        } else {
            Issue.record("Expected a speech-start event")
        }

        var endEvent: VoiceActivityStreamEvent?
        for _ in 0..<4 {
            result = VoiceActivityBoundaryDetector.process(
                probability: 0,
                chunkSampleCount: chunkSize,
                state: state,
                configuration: configuration,
                entryThreshold: 0.85,
                exitThreshold: 0.7
            )
            state = result.state
            endEvent = result.event ?? endEvent
        }

        let firstSilentChunkEnd = 3 * chunkSize
        let expectedEnd = firstSilentChunkEnd + Int(0.45 * 16_000) - chunkSize
        #expect(endEvent?.sampleIndex == expectedEnd)
        if case .speechEnd? = endEvent?.kind {
            // Expected end event.
        } else {
            Issue.record("Expected a speech-end event")
        }
    }

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

    @MainActor
    @Test("Converter exposes its final sample-rate filter tail")
    func streamingConversionFinish() throws {
        let sourceRate = 48_000.0
        let frames = 4_800
        let converter = StreamingAudioConverter()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ), let channel = buffer.floatChannelData?[0] else {
            Issue.record("Could not create the converter-tail fixture")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            channel[frame] = sin(2 * .pi * 440 * Float(frame) / Float(sourceRate))
        }

        let converted = try converter.resampleBuffer(buffer)
        let tail = try converter.finish()

        #expect(abs(converted.count + tail.count - 1_600) <= 256)
        #expect(!converted.isEmpty)
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
