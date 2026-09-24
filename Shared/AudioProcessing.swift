// Audio resampling and streaming voice activity detection used by both apps.
//
// The VAD model invocation and hysteresis state machine are adapted from
// FluidAudio 0.13.6 (revision 57551cd90e0bbec342766244358bcf08afb05290),
// licensed under Apache-2.0. Yaprflow intentionally keeps only this narrow
// surface; FluidAudio's downloader, diarization, clustering, and TTS code are
// not linked into the applications. See THIRD_PARTY_NOTICES.md.

@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Foundation

/// Converts PCM amplitude into a stable 0...1 value for recording UI meters.
/// The logarithmic scale keeps ordinary speech visibly responsive without
/// letting a single clipped sample dominate the display.
nonisolated enum AudioLevelMeter {
    static func normalizedLevel(
        for samples: [Float],
        floorDecibels: Float = -55,
        ceilingDecibels: Float = -8
    ) -> Float {
        guard !samples.isEmpty, ceilingDecibels > floorDecibels else { return 0 }

        var sumOfSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        let rootMeanSquare = sqrt(sumOfSquares / Double(samples.count))
        guard rootMeanSquare > 0 else { return 0 }

        let decibels = Float(20 * log10(rootMeanSquare))
        return min(
            1,
            max(0, (decibels - floorDecibels) / (ceilingDecibels - floorDecibels))
        )
    }
}

/// Recognizes microphone segments made entirely of Mac playback. This is a
/// conservative alternative to input-device voice processing: it never
/// suppresses a segment with independent local speech and it does not alter
/// another app's microphone or speaker levels. Only a rolling, downsampled
/// reference is retained; no audio is persisted.
@MainActor
final class MeetingPlaybackEchoDetector {
    private static let decimation = 4
    private static let referenceRate = 4_000
    private static let retainedReferenceSamples = 35 * referenceRate
    private static let searchRadius = 3 * referenceRate
    private static let searchStep = 20
    private static let windowLength = referenceRate / 5
    private static let minimumWindowMeanSquare: Double = 0.000_004

    private var reference = RollingSessionAudio()
    private var pendingReferenceSum: Float = 0
    private var pendingReferenceCount = 0

    var retainedReferenceSampleCount: Int { reference.retainedSampleCount }
    private(set) var suppressedSegmentCount = 0

    func reset() {
        reference.reset(keepingCapacity: true)
        pendingReferenceSum = 0
        pendingReferenceCount = 0
        suppressedSegmentCount = 0
    }

    func appendSystemSamples(_ samples: [Float]) {
        var reduced: [Float] = []
        reduced.reserveCapacity((samples.count + Self.decimation - 1) / Self.decimation)
        for sample in samples {
            pendingReferenceSum += sample
            pendingReferenceCount += 1
            if pendingReferenceCount == Self.decimation {
                reduced.append(pendingReferenceSum / Float(Self.decimation))
                pendingReferenceSum = 0
                pendingReferenceCount = 0
            }
        }
        reference.append(reduced)
        reference.discard(before: reference.endIndex - Self.retainedReferenceSamples)
    }

    func isPlaybackOnly(_ microphoneSamples: [Float], startingAt microphoneSampleIndex: Int) -> Bool {
        let microphone = Self.downsample(microphoneSamples)
        let windowLength = Self.windowLength
        guard microphone.count >= windowLength,
              reference.retainedSampleCount >= windowLength else { return false }

        let microphoneStart = microphoneSampleIndex / Self.decimation
        let windows = stride(from: 0, through: microphone.count - windowLength, by: windowLength)
            .filter { Self.meanSquare(microphone, at: $0, count: windowLength) >= Self.minimumWindowMeanSquare }
        guard !windows.isEmpty else { return false }

        // Search one energetic window for the capture-clock offset plus the
        // speaker-to-microphone acoustic delay. The offset then stays fixed
        // while every voiced window is checked for local speech.
        let probe = windows.max {
            Self.meanSquare(microphone, at: $0, count: windowLength)
                < Self.meanSquare(microphone, at: $1, count: windowLength)
        } ?? windows[0]
        let expected = microphoneStart + probe
        let searchStart = max(reference.startIndex, expected - Self.searchRadius)
        let searchEnd = min(reference.endIndex - windowLength, expected + Self.searchRadius)
        guard searchEnd >= searchStart else { return false }
        let searchAudio = reference.samples(from: searchStart, to: searchEnd + windowLength)

        var bestPosition = searchStart
        var bestCorrelation = 0.0
        for position in stride(from: searchStart, through: searchEnd, by: Self.searchStep) {
            let correlation = Self.correlation(
                microphone, microphoneOffset: probe,
                reference: searchAudio, referenceOffset: position - searchStart,
                count: windowLength
            )
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestPosition = position
            }
        }
        let fineStart = max(searchStart, bestPosition - Self.searchStep)
        let fineEnd = min(searchEnd, bestPosition + Self.searchStep)
        for position in fineStart...fineEnd {
            let correlation = Self.correlation(
                microphone, microphoneOffset: probe,
                reference: searchAudio, referenceOffset: position - searchStart,
                count: windowLength
            )
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestPosition = position
            }
        }
        guard bestCorrelation >= 0.88 else { return false }

        let offset = bestPosition - expected
        var totalCorrelation = 0.0
        for window in windows {
            let referenceStart = microphoneStart + window + offset
            guard referenceStart >= reference.startIndex,
                  referenceStart + windowLength <= reference.endIndex else { return false }
            let referenceWindow = reference.samples(
                from: referenceStart,
                to: referenceStart + windowLength
            )
            let correlation = Self.correlation(
                microphone, microphoneOffset: window,
                reference: referenceWindow, referenceOffset: 0,
                count: windowLength
            )
            // One independently spoken window keeps the entire microphone
            // segment. Text reconciliation can still remove echoed words.
            guard correlation >= 0.72 else { return false }
            totalCorrelation += correlation
        }
        let isPlaybackOnly = totalCorrelation / Double(windows.count) >= 0.85
        if isPlaybackOnly { suppressedSegmentCount += 1 }
        return isPlaybackOnly
    }

    private static func downsample(_ samples: [Float]) -> [Float] {
        guard samples.count >= decimation else { return [] }
        var reduced: [Float] = []
        reduced.reserveCapacity(samples.count / decimation)
        for start in stride(from: 0, through: samples.count - decimation, by: decimation) {
            reduced.append(
                (samples[start] + samples[start + 1] + samples[start + 2] + samples[start + 3]) / Float(decimation)
            )
        }
        return reduced
    }

    private static func meanSquare(_ samples: [Float], at offset: Int, count: Int) -> Double {
        var sum = 0.0
        for index in offset..<(offset + count) {
            let value = Double(samples[index])
            sum += value * value
        }
        return sum / Double(count)
    }

    private static func correlation(
        _ microphone: [Float], microphoneOffset: Int,
        reference: [Float], referenceOffset: Int,
        count: Int
    ) -> Double {
        var cross = 0.0
        var microphoneEnergy = 0.0
        var referenceEnergy = 0.0
        for index in 0..<count {
            let microphoneSample = Double(microphone[microphoneOffset + index])
            let referenceSample = Double(reference[referenceOffset + index])
            cross += microphoneSample * referenceSample
            microphoneEnergy += microphoneSample * microphoneSample
            referenceEnergy += referenceSample * referenceSample
        }
        guard microphoneEnergy >= Double(count) * minimumWindowMeanSquare,
              referenceEnergy >= Double(count) * minimumWindowMeanSquare else { return 0 }
        return cross / sqrt(microphoneEnergy * referenceEnergy)
    }
}

/// A reusable, low-latency PCM converter for microphone buffers.
///
/// `AVAudioConverter` preserves its sample-rate state across adjacent capture
/// buffers. A new converter is created only when the hardware input format
/// changes, preventing boundary artifacts and repeated setup work.
@MainActor
final class StreamingAudioConverter {
    private struct FormatKey: Equatable {
        let sampleRate: Double
        let formatID: AudioFormatID
        let formatFlags: AudioFormatFlags
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32
        let channelLayoutTag: AudioChannelLayoutTag?

        init(_ format: AVAudioFormat) {
            let description = format.streamDescription.pointee
            sampleRate = description.mSampleRate
            formatID = description.mFormatID
            formatFlags = description.mFormatFlags
            bytesPerPacket = description.mBytesPerPacket
            framesPerPacket = description.mFramesPerPacket
            bytesPerFrame = description.mBytesPerFrame
            channelsPerFrame = description.mChannelsPerFrame
            bitsPerChannel = description.mBitsPerChannel
            channelLayoutTag = format.channelLayout?.layoutTag
        }
    }

    /// The converter calls its input block synchronously, but the callback is
    /// imported as sendable. This lock-backed holder makes the one-shot handoff
    /// explicit and avoids unsafe mutation of a captured local variable.
    nonisolated private final class InputFeeder: @unchecked Sendable {
        private let lock = NSLock()
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }

            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    nonisolated private final class EndOfStreamFeeder: @unchecked Sendable {
        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            status.pointee = .endOfStream
            return nil
        }
    }

    private let targetFormat: AVAudioFormat?
    private var sourceKey: FormatKey?
    private var converter: AVAudioConverter?

    init(sampleRate: Double = 16_000) {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// Starts the next recording with clean sample-rate-converter history while
    /// retaining the converter allocation when the hardware format is stable.
    func reset() {
        converter?.reset()
    }

    func resampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        guard let targetFormat else {
            throw AudioConversionError.cannotCreateConverter
        }
        let inputFormat = buffer.format

        if matchesTarget(inputFormat) {
            return samples(from: buffer)
        }

        let key = FormatKey(inputFormat)
        if converter == nil || sourceKey != key {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioConversionError.cannotCreateConverter
            }
            newConverter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
            newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = newConverter
            sourceKey = key
        }

        guard let converter else {
            throw AudioConversionError.cannotCreateConverter
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let estimatedFrames = ceil(Double(buffer.frameLength) * ratio)
        let capacity = AVAudioFrameCount(max(1, estimatedFrames + 256))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw AudioConversionError.cannotCreateBuffer
        }

        let feeder = InputFeeder(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError,
            withInputFrom: { _, inputStatus in
                feeder.next(status: inputStatus)
            }
        )
        if status == .error {
            throw AudioConversionError.conversionFailed(conversionError)
        }

        return samples(from: output)
    }

    /// Flushes samples retained by the sample-rate converter after the capture
    /// tap has stopped. Without the explicit end-of-stream signal, the final
    /// few milliseconds can remain inside the converter's filter history.
    func finish() throws -> [Float] {
        guard let converter else { return [] }
        guard let targetFormat else {
            throw AudioConversionError.cannotCreateConverter
        }

        let feeder = EndOfStreamFeeder()
        var drained: [Float] = []
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 4_096
            ) else {
                throw AudioConversionError.cannotCreateBuffer
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError,
                withInputFrom: { _, inputStatus in
                    feeder.next(status: inputStatus)
                }
            )
            if status == .error {
                throw AudioConversionError.conversionFailed(conversionError)
            }
            drained.append(contentsOf: samples(from: output))
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        converter.reset()
        return drained
    }

    private func matchesTarget(_ format: AVAudioFormat) -> Bool {
        guard let targetFormat else { return false }
        return format.sampleRate == targetFormat.sampleRate
            && format.channelCount == 1
            && format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved
    }

    private func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
    }
}

nonisolated enum AudioConversionError: LocalizedError {
    case cannotCreateConverter
    case cannotCreateBuffer
    case conversionFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .cannotCreateConverter:
            return "The microphone audio format cannot be converted to 16 kHz mono."
        case .cannotCreateBuffer:
            return "A converted microphone audio buffer could not be allocated."
        case .conversionFailed(let error):
            return "Microphone audio conversion failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

nonisolated struct VoiceActivitySegmentationConfiguration: Sendable {
    var minSilenceDuration: TimeInterval
    var speechStartPadding: TimeInterval
    var speechEndPadding: TimeInterval
    var negativeThreshold: Float?
    var negativeThresholdOffset: Float

    init(
        minSilenceDuration: TimeInterval = 0.75,
        speechStartPadding: TimeInterval = 0.35,
        speechEndPadding: TimeInterval = 0.45,
        negativeThreshold: Float? = nil,
        negativeThresholdOffset: Float = 0.15
    ) {
        self.minSilenceDuration = minSilenceDuration.isFinite
            ? max(0, minSilenceDuration) : 0.75
        self.speechStartPadding = speechStartPadding.isFinite
            ? max(0, speechStartPadding) : 0.35
        self.speechEndPadding = speechEndPadding.isFinite
            ? max(0, speechEndPadding) : 0.45
        if let negativeThreshold, negativeThreshold.isFinite {
            self.negativeThreshold = min(max(negativeThreshold, 0), 1)
        } else {
            self.negativeThreshold = nil
        }
        self.negativeThresholdOffset = negativeThresholdOffset.isFinite
            ? max(0, negativeThresholdOffset) : 0.15
    }

    func effectiveNegativeThreshold(baseThreshold: Float) -> Float {
        negativeThreshold ?? max(baseThreshold - negativeThresholdOffset, 0.01)
    }
}

/// Pads short offline recognition requests without shifting their timestamps.
/// FluidAudio's Parakeet API rejects requests shorter than one second even
/// though brief words are valid dictation and meeting utterances.
nonisolated enum OfflineRecognitionAudio {
    static func paddedToMinimumDuration(
        _ samples: [Float],
        sampleRate: Int = 16_000,
        minimumDuration: TimeInterval = 1
    ) -> [Float] {
        let minimumSamples = max(0, Int((minimumDuration * Double(sampleRate)).rounded(.up)))
        guard samples.count < minimumSamples else { return samples }
        return samples + [Float](repeating: 0, count: minimumSamples - samples.count)
    }
}

nonisolated private struct VoiceActivityModelState: Sendable {
    static let contextLength = 64
    static let recurrentStateLength = 128

    var hiddenState: [Float]
    var cellState: [Float]
    var context: [Float]

    static func initial() -> Self {
        Self(
            hiddenState: [Float](repeating: 0, count: recurrentStateLength),
            cellState: [Float](repeating: 0, count: recurrentStateLength),
            context: [Float](repeating: 0, count: contextLength)
        )
    }
}

nonisolated struct VoiceActivityStreamState: Sendable {
    fileprivate var modelState = VoiceActivityModelState.initial()
    fileprivate var triggered = false
    fileprivate var tentativeEndSample: Int?
    fileprivate var processedSamples = 0
}

nonisolated struct VoiceActivityStreamEvent: Sendable {
    enum Kind: Sendable {
        case speechStart
        case speechEnd
    }

    let kind: Kind
    let sampleIndex: Int
}

nonisolated struct VoiceActivityStreamResult: Sendable {
    let state: VoiceActivityStreamState
    let event: VoiceActivityStreamEvent?
}

nonisolated enum VoiceActivityDetectorError: LocalizedError {
    case modelInputInvalid(String)
    case modelOutputMissing(String)
    case modelOutputInvalid(String)
    case modelProcessingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelInputInvalid(let name):
            return "The voice detector received invalid \(name) input."
        case .modelOutputMissing(let name):
            return "The voice detector did not produce its \(name) output."
        case .modelOutputInvalid(let name):
            return "The voice detector produced invalid \(name) output."
        case .modelProcessingFailed(let error):
            return "Voice detection failed: \(error.localizedDescription)"
        }
    }
}

/// Minimal streaming wrapper around the bundled Silero Core ML model.
actor VoiceActivityDetector {
    struct Configuration: Sendable {
        var defaultThreshold: Float

        init(defaultThreshold: Float = 0.85) {
            self.defaultThreshold = defaultThreshold.isFinite
                ? min(max(defaultThreshold, 0), 1) : 0.85
        }
    }

    static let chunkSize = 4_096
    static let sampleRate = 16_000

    private static let modelInputSize =
        chunkSize + VoiceActivityModelState.contextLength

    private let configuration: Configuration
    private let model: MLModel
    private var audioInput: MLMultiArray?
    private var hiddenInput: MLMultiArray?
    private var cellInput: MLMultiArray?

    init(configuration: Configuration = .init(), model: MLModel) {
        self.configuration = configuration
        self.model = model
    }

    func makeStreamState() -> VoiceActivityStreamState {
        VoiceActivityStreamState()
    }

    func processStreamingChunk(
        _ audioChunk: [Float],
        state: VoiceActivityStreamState,
        configuration segmentation: VoiceActivitySegmentationConfiguration
    ) throws -> VoiceActivityStreamResult {
        let (probability, modelState) = try processChunk(
            audioChunk,
            state: state.modelState
        )

        let entryThreshold: Float
        if let exitThreshold = segmentation.negativeThreshold {
            entryThreshold = min(1, exitThreshold + segmentation.negativeThresholdOffset)
        } else {
            entryThreshold = configuration.defaultThreshold
        }
        let exitThreshold = segmentation.effectiveNegativeThreshold(
            baseThreshold: entryThreshold
        )
        let result = VoiceActivityBoundaryDetector.process(
            probability: probability,
            chunkSampleCount: audioChunk.count,
            state: state,
            configuration: segmentation,
            entryThreshold: entryThreshold,
            exitThreshold: exitThreshold,
            sampleRate: Self.sampleRate
        )
        var nextState = result.state
        nextState.modelState = modelState
        return VoiceActivityStreamResult(state: nextState, event: result.event)
    }

    private func processChunk(
        _ audioChunk: [Float],
        state: VoiceActivityModelState
    ) throws -> (Float, VoiceActivityModelState) {
        var chunk = audioChunk
        if chunk.count < Self.chunkSize {
            chunk.append(
                contentsOf: repeatElement(
                    chunk.last ?? 0,
                    count: Self.chunkSize - chunk.count
                )
            )
        } else if chunk.count > Self.chunkSize {
            chunk.removeSubrange(Self.chunkSize...)
        }

        do {
            let buffers = try inputBuffers()
            clear(buffers.audio)
            clear(buffers.hidden)
            clear(buffers.cell)
            try copy(state.context, to: buffers.audio)
            try copy(
                chunk,
                to: buffers.audio,
                offset: VoiceActivityModelState.contextLength
            )
            try copy(state.hiddenState, to: buffers.hidden)
            try copy(state.cellState, to: buffers.cell)

            let inputs = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": buffers.audio,
                "hidden_state": buffers.hidden,
                "cell_state": buffers.cell,
            ])
            let output = try model.prediction(from: inputs)
            let probabilityArray = try feature(
                named: "vad_output",
                in: output,
                minimumCount: 1
            )
            let hidden = try feature(
                named: "new_hidden_state",
                in: output,
                minimumCount: VoiceActivityModelState.recurrentStateLength
            )
            let cell = try feature(
                named: "new_cell_state",
                in: output,
                minimumCount: VoiceActivityModelState.recurrentStateLength
            )

            let probability = probabilityArray.dataPointer
                .assumingMemoryBound(to: Float.self)[0]
            let nextState = VoiceActivityModelState(
                hiddenState: values(
                    from: hidden,
                    count: VoiceActivityModelState.recurrentStateLength
                ),
                cellState: values(
                    from: cell,
                    count: VoiceActivityModelState.recurrentStateLength
                ),
                context: Array(chunk.suffix(VoiceActivityModelState.contextLength))
            )
            return (probability, nextState)
        } catch let error as VoiceActivityDetectorError {
            throw error
        } catch {
            throw VoiceActivityDetectorError.modelProcessingFailed(error)
        }
    }

    private func inputBuffers() throws -> (
        audio: MLMultiArray,
        hidden: MLMultiArray,
        cell: MLMultiArray
    ) {
        if audioInput == nil {
            audioInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.modelInputSize)],
                dataType: .float32
            )
            hiddenInput = try MLMultiArray(
                shape: [1, NSNumber(value: VoiceActivityModelState.recurrentStateLength)],
                dataType: .float32
            )
            cellInput = try MLMultiArray(
                shape: [1, NSNumber(value: VoiceActivityModelState.recurrentStateLength)],
                dataType: .float32
            )
        }

        guard let audioInput, let hiddenInput, let cellInput else {
            throw VoiceActivityDetectorError.modelOutputMissing("input buffer")
        }
        return (audioInput, hiddenInput, cellInput)
    }

    private func feature(
        named name: String,
        in provider: MLFeatureProvider,
        minimumCount: Int
    ) throws -> MLMultiArray {
        let value = provider.featureValue(for: name)?.multiArrayValue ?? {
            guard let resolvedName = provider.featureNames.first(where: {
                $0.localizedCaseInsensitiveContains(name)
            }) else { return nil }
            return provider.featureValue(for: resolvedName)?.multiArrayValue
        }()
        guard let value else {
            throw VoiceActivityDetectorError.modelOutputMissing(name)
        }
        guard value.dataType == .float32, value.count >= minimumCount else {
            throw VoiceActivityDetectorError.modelOutputInvalid(name)
        }
        return value
    }

    private func clear(_ array: MLMultiArray) {
        array.dataPointer.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: array.count * MemoryLayout<Float>.size
        )
    }

    private func copy(
        _ values: [Float],
        to array: MLMultiArray,
        offset: Int = 0
    ) throws {
        guard array.dataType == .float32,
              offset >= 0,
              offset <= array.count,
              values.count <= array.count - offset else {
            throw VoiceActivityDetectorError.modelInputInvalid("buffer")
        }
        let destination = array.dataPointer
            .assumingMemoryBound(to: Float.self)
            .advanced(by: offset)
        values.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            destination.update(from: baseAddress, count: source.count)
        }
    }

    private func values(from array: MLMultiArray, count: Int) -> [Float] {
        Array(
            UnsafeBufferPointer(
                start: array.dataPointer.assumingMemoryBound(to: Float.self),
                count: count
            )
        )
    }
}

/// Pure VAD boundary state machine, separated from Core ML inference so onset,
/// silence, and padding behavior can be tested deterministically.
nonisolated enum VoiceActivityBoundaryDetector {
    static func process(
        probability: Float,
        chunkSampleCount: Int,
        state: VoiceActivityStreamState,
        configuration: VoiceActivitySegmentationConfiguration,
        entryThreshold: Float,
        exitThreshold: Float,
        sampleRate: Int = 16_000
    ) -> VoiceActivityStreamResult {
        var nextState = state
        nextState.processedSamples += chunkSampleCount

        let startPadding = Int(configuration.speechStartPadding * Double(sampleRate))
        let endPadding = Int(configuration.speechEndPadding * Double(sampleRate))
        let minimumSilence = Int(configuration.minSilenceDuration * Double(sampleRate))

        var event: VoiceActivityStreamEvent?
        if probability >= entryThreshold {
            nextState.tentativeEndSample = nil
            if !nextState.triggered {
                nextState.triggered = true
                let start = max(
                    0,
                    nextState.processedSamples - startPadding - chunkSampleCount
                )
                event = VoiceActivityStreamEvent(kind: .speechStart, sampleIndex: start)
            }
        } else if probability < exitThreshold, nextState.triggered {
            if nextState.tentativeEndSample == nil {
                nextState.tentativeEndSample = nextState.processedSamples
            }
            if let silenceStart = nextState.tentativeEndSample,
               nextState.processedSamples - silenceStart >= minimumSilence {
                let end = max(0, silenceStart + endPadding - chunkSampleCount)
                nextState.triggered = false
                nextState.tentativeEndSample = nil
                event = VoiceActivityStreamEvent(kind: .speechEnd, sampleIndex: end)
            }
        }

        return VoiceActivityStreamResult(state: nextState, event: event)
    }
}
