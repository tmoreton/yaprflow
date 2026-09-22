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

    private let targetFormat: AVAudioFormat
    private var sourceKey: FormatKey?
    private var converter: AVAudioConverter?

    init(sampleRate: Double = 16_000) {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("Unable to create the 16 kHz mono audio format")
        }
        self.targetFormat = targetFormat
    }

    /// Starts the next recording with clean sample-rate-converter history while
    /// retaining the converter allocation when the hardware format is stable.
    func reset() {
        converter?.reset()
    }

    func resampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
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

    private func matchesTarget(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == targetFormat.sampleRate
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
    var speechPadding: TimeInterval
    var negativeThreshold: Float?
    var negativeThresholdOffset: Float

    init(
        minSilenceDuration: TimeInterval = 0.75,
        speechPadding: TimeInterval = 0.1,
        negativeThreshold: Float? = nil,
        negativeThresholdOffset: Float = 0.15
    ) {
        precondition(minSilenceDuration >= 0)
        precondition(speechPadding >= 0)
        precondition(negativeThresholdOffset >= 0)
        if let negativeThreshold {
            precondition((0...1).contains(negativeThreshold))
        }

        self.minSilenceDuration = minSilenceDuration
        self.speechPadding = speechPadding
        self.negativeThreshold = negativeThreshold
        self.negativeThresholdOffset = negativeThresholdOffset
    }

    func effectiveNegativeThreshold(baseThreshold: Float) -> Float {
        negativeThreshold ?? max(baseThreshold - negativeThresholdOffset, 0.01)
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
    case modelOutputMissing(String)
    case modelProcessingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelOutputMissing(let name):
            return "The voice detector did not produce its \(name) output."
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
            precondition((0...1).contains(defaultThreshold))
            self.defaultThreshold = defaultThreshold
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

        var nextState = state
        nextState.modelState = modelState
        nextState.processedSamples += audioChunk.count

        let entryThreshold: Float
        if let exitThreshold = segmentation.negativeThreshold {
            entryThreshold = min(1, exitThreshold + segmentation.negativeThresholdOffset)
        } else {
            entryThreshold = configuration.defaultThreshold
        }
        let exitThreshold = segmentation.effectiveNegativeThreshold(
            baseThreshold: entryThreshold
        )
        let padding = Int(segmentation.speechPadding * Double(Self.sampleRate))
        let minimumSilence = Int(
            segmentation.minSilenceDuration * Double(Self.sampleRate)
        )

        var event: VoiceActivityStreamEvent?
        if probability >= entryThreshold {
            nextState.tentativeEndSample = nil
            if !nextState.triggered {
                nextState.triggered = true
                let start = max(
                    0,
                    nextState.processedSamples - padding - audioChunk.count
                )
                event = VoiceActivityStreamEvent(
                    kind: .speechStart,
                    sampleIndex: start
                )
            }
        } else if probability < exitThreshold, nextState.triggered {
            if nextState.tentativeEndSample == nil {
                nextState.tentativeEndSample = nextState.processedSamples
            }
            if let silenceStart = nextState.tentativeEndSample,
               nextState.processedSamples - silenceStart >= minimumSilence {
                let end = max(0, silenceStart + padding - audioChunk.count)
                nextState.triggered = false
                nextState.tentativeEndSample = nil
                event = VoiceActivityStreamEvent(
                    kind: .speechEnd,
                    sampleIndex: end
                )
            }
        }

        return VoiceActivityStreamResult(state: nextState, event: event)
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
            copy(state.context, to: buffers.audio)
            copy(
                chunk,
                to: buffers.audio,
                offset: VoiceActivityModelState.contextLength
            )
            copy(state.hiddenState, to: buffers.hidden)
            copy(state.cellState, to: buffers.cell)

            let inputs = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": buffers.audio,
                "hidden_state": buffers.hidden,
                "cell_state": buffers.cell,
            ])
            let output = try model.prediction(from: inputs)
            let probabilityArray = try feature(
                named: "vad_output",
                in: output
            )
            let hidden = try feature(
                named: "new_hidden_state",
                in: output
            )
            let cell = try feature(
                named: "new_cell_state",
                in: output
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
        in provider: MLFeatureProvider
    ) throws -> MLMultiArray {
        if let value = provider.featureValue(for: name)?.multiArrayValue {
            return value
        }
        if let resolvedName = provider.featureNames.first(where: {
            $0.localizedCaseInsensitiveContains(name)
        }), let value = provider.featureValue(for: resolvedName)?.multiArrayValue {
            return value
        }
        throw VoiceActivityDetectorError.modelOutputMissing(name)
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
    ) {
        precondition(offset >= 0 && offset + values.count <= array.count)
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
