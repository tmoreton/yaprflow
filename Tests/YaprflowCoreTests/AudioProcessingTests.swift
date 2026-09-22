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

    @MainActor
    @Test("Mac playback echoed into the microphone is rejected without a text match")
    func playbackOnlyMicrophoneAudio() {
        let detector = MeetingPlaybackEchoDetector()
        let system = Self.speechLikeSamples(count: 8 * 16_000, seed: 17)
        detector.appendSystemSamples(system)
        let microphoneStart = 3 * 16_000
        let acousticDelay = 1_920
        let echo = (0..<(2 * 16_000)).map { index in
            system[microphoneStart + index - acousticDelay] * 0.32
        }

        #expect(detector.isPlaybackOnly(echo, startingAt: microphoneStart))
    }

    @MainActor
    @Test("A short echoed microphone fragment is rejected")
    func shortPlaybackEcho() {
        let detector = MeetingPlaybackEchoDetector()
        let system = Self.speechLikeSamples(count: 5 * 16_000, seed: 19)
        detector.appendSystemSamples(system)
        let microphoneStart = 2 * 16_000
        let echo = Array(system[(microphoneStart - 960)..<(microphoneStart - 960 + 9_600)])
            .map { $0 * 0.4 }

        #expect(detector.isPlaybackOnly(echo, startingAt: microphoneStart))
    }

    @MainActor
    @Test("Independent local speech is kept even while Mac audio is playing")
    func localSpeechOverPlayback() {
        let detector = MeetingPlaybackEchoDetector()
        let system = Self.speechLikeSamples(count: 8 * 16_000, seed: 23)
        let local = Self.speechLikeSamples(count: 2 * 16_000, seed: 47, fundamental: 397)
        detector.appendSystemSamples(system)
        let microphoneStart = 3 * 16_000
        let echoWithInterruption = (0..<(2 * 16_000)).map { index in
            let echo = system[microphoneStart + index - 1_280] * 0.32
            let interruption = (9_000..<17_000).contains(index) ? local[index] * 0.8 : 0
            return echo + interruption
        }

        let mixedIsPlaybackOnly = detector.isPlaybackOnly(echoWithInterruption, startingAt: microphoneStart)
        let localIsPlaybackOnly = detector.isPlaybackOnly(local, startingAt: microphoneStart)
        #expect(!mixedIsPlaybackOnly)
        #expect(!localIsPlaybackOnly)
    }

    @MainActor
    @Test("Microphone speech is never discarded without a usable playback reference")
    func absentPlaybackReference() {
        let detector = MeetingPlaybackEchoDetector()
        let local = Self.speechLikeSamples(count: 16_000, seed: 53, fundamental: 397)
        let beforeReference = detector.isPlaybackOnly(local, startingAt: 16_000)
        detector.appendSystemSamples([Float](repeating: 0, count: 16_000))
        let silentReference = detector.isPlaybackOnly(local, startingAt: 16_000)

        #expect(!beforeReference)
        #expect(!silentReference)
    }

    @MainActor
    @Test("Playback reference stays bounded for long meetings")
    func echoReferenceIsBounded() {
        let detector = MeetingPlaybackEchoDetector()
        for _ in 0..<100 {
            detector.appendSystemSamples([Float](repeating: 0.1, count: 16_000))
        }

        #expect(detector.retainedReferenceSampleCount == 35 * 4_000)
        detector.reset()
        #expect(detector.retainedReferenceSampleCount == 0)
    }

    private static func speechLikeSamples(
        count: Int,
        seed: UInt64,
        fundamental: Float = 157
    ) -> [Float] {
        var state = seed
        return (0..<count).map { index in
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let noise = Float(state >> 40) / Float(1 << 24) * 2 - 1
            let seconds = Float(index) / 16_000
            let voiced = sin(2 * .pi * fundamental * seconds) * 0.55
                + sin(2 * .pi * (fundamental * 1.8) * seconds) * 0.25
            return (voiced + noise * 0.2) * 0.12
        }
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
