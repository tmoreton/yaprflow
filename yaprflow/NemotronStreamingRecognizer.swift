import Foundation
import SherpaOnnx

enum NemotronRecognizerError: LocalizedError {
    case incompleteModel(URL)

    var errorDescription: String? {
        switch self {
        case let .incompleteModel(url):
            return "Yaprflow's bundled speech model is incomplete. Please reinstall the app. Missing \(url.lastPathComponent)."
        }
    }
}

/// Owns sherpa-onnx's stateful online recognizer away from the main actor.
/// A single instance keeps the model warm while each utterance gets a fresh
/// streaming state.
actor NemotronStreamingRecognizer {
    static let sampleRate = 16_000

    // The caller feeds audio every 320 ms so partials remain responsive. The
    // selected ONNX export has a 1120 ms chunk size; sherpa-onnx buffers these
    // smaller waveform feeds as needed.
    private static let chunkSampleCount = 5_120
    // The benchmarked 660 ms tail clipped final words with this export. A
    // 1300 ms tail exposes the complete final model chunk before sealing it.
    private static let finalPaddingSampleCount = 20_800

    private enum StreamState: Equatable {
        case fresh
        case accepting
        case finished
    }

    private let recognizer: SherpaOnnxRecognizer
    private var streamState: StreamState = .fresh
    private var pendingSamples: [Float] = []

    init(modelDirectory: URL) throws {
        let encoder = modelDirectory.appendingPathComponent(
            "encoder.int8.onnx"
        )
        let decoder = modelDirectory.appendingPathComponent(
            "decoder.int8.onnx"
        )
        let joiner = modelDirectory.appendingPathComponent(
            "joiner.int8.onnx"
        )
        let tokens = modelDirectory.appendingPathComponent("tokens.txt")

        for file in [encoder, decoder, joiner, tokens] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: file.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                throw NemotronRecognizerError.incompleteModel(file)
            }
        }

        let transducerConfig = sherpaOnnxOnlineTransducerModelConfig(
            encoder: encoder.path,
            decoder: decoder.path,
            joiner: joiner.path
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokens.path,
            transducer: transducerConfig,
            numThreads: 2,
            provider: "cpu"
        )
        let featureConfig = sherpaOnnxFeatureConfig(
            sampleRate: Self.sampleRate,
            featureDim: 80
        )
        var recognizerConfig = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featureConfig,
            modelConfig: modelConfig,
            enableEndpoint: false,
            decodingMethod: "greedy_search",
            maxActivePaths: 1,
            hotwordsFile: "",
            hotwordsBuf: "",
            hotwordsBufSize: 0
        )

        recognizer = SherpaOnnxRecognizer(config: &recognizerConfig)
        recognizer.setOption(key: "language", value: "auto")
        pendingSamples.reserveCapacity(Self.chunkSampleCount * 2)
    }

    func beginStream() {
        if streamState != .fresh {
            // Passing no hotwords deliberately creates the normal stream. The
            // accuracy benchmark found that hotwords hurt this general-purpose
            // dictation corpus.
            recognizer.reset()
        }
        recognizer.setOption(key: "language", value: "auto")
        pendingSamples.removeAll(keepingCapacity: true)
        streamState = .accepting
    }

    /// Accept live 16 kHz mono samples and return the newest partial result.
    /// Only complete 320 ms feeds enter sherpa-onnx during live recognition.
    func accept(_ samples: [Float]) -> String {
        guard streamState == .accepting, !samples.isEmpty else {
            return currentText
        }

        pendingSamples.append(contentsOf: samples)
        while pendingSamples.count >= Self.chunkSampleCount {
            let chunk = Array(pendingSamples.prefix(Self.chunkSampleCount))
            pendingSamples.removeFirst(Self.chunkSampleCount)
            recognizer.acceptWaveform(samples: chunk, sampleRate: Self.sampleRate)
            decodeAvailableFrames()
        }

        return currentText
    }

    /// Flush the last sub-chunk, add the model's required right-context
    /// silence, signal end-of-input, and drain every decodable frame.
    func finishStream() -> String {
        guard streamState == .accepting else { return "" }

        if !pendingSamples.isEmpty {
            recognizer.acceptWaveform(
                samples: pendingSamples,
                sampleRate: Self.sampleRate
            )
            pendingSamples.removeAll(keepingCapacity: true)
            decodeAvailableFrames()
        }

        recognizer.acceptWaveform(
            samples: [Float](
                repeating: 0,
                count: Self.finalPaddingSampleCount
            ),
            sampleRate: Self.sampleRate
        )
        recognizer.inputFinished()
        decodeAvailableFrames()

        let text = currentText
        streamState = .finished
        return text
    }

    func discardStream() {
        recognizer.reset()
        pendingSamples.removeAll(keepingCapacity: true)
        streamState = .fresh
    }

    private func decodeAvailableFrames() {
        while recognizer.isReady() {
            recognizer.decode()
        }
    }

    private var currentText: String {
        recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
