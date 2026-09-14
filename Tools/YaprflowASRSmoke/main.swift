import Foundation
import SherpaOnnx

private enum SmokeTestError: LocalizedError {
    case usage
    case missingModelFile(String)
    case unreadableWave(String)
    case emptyTranscript(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: yaprflow-asr-smoke [--language CODE] MODEL_DIRECTORY WAV [WAV ...]"
        case .missingModelFile(let path):
            return "Missing model file: \(path)"
        case .unreadableWave(let path):
            return "Could not read mono PCM wave file: \(path)"
        case .emptyTranscript(let path):
            return "Recognizer returned an empty transcript: \(path)"
        }
    }
}

private let sampleRate = 16_000
private let feedDuration = 0.32
private let finalizationTailDuration = 1.3

private func resampleToModelRate(_ samples: [Float], from sourceRate: Int) -> [Float] {
    guard sourceRate != sampleRate, samples.count > 1 else { return samples }

    let ratio = Double(sourceRate) / Double(sampleRate)
    let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
    guard outputCount > 0 else { return [] }

    return (0..<outputCount).map { outputIndex in
        let sourcePosition = Double(outputIndex) * ratio
        let lower = min(Int(sourcePosition), samples.count - 1)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = Float(sourcePosition - Double(lower))
        return samples[lower] + (samples[upper] - samples[lower]) * fraction
    }
}

private func makeRecognizer(modelDirectory: URL) throws -> SherpaOnnxRecognizer {
    let files = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
    for file in files {
        let path = modelDirectory.appendingPathComponent(file).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SmokeTestError.missingModelFile(path)
        }
    }

    let transducer = sherpaOnnxOnlineTransducerModelConfig(
        encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx").path,
        decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx").path,
        joiner: modelDirectory.appendingPathComponent("joiner.int8.onnx").path
    )
    let model = sherpaOnnxOnlineModelConfig(
        tokens: modelDirectory.appendingPathComponent("tokens.txt").path,
        transducer: transducer,
        numThreads: 2,
        provider: "cpu"
    )
    let features = sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 80)
    var config = sherpaOnnxOnlineRecognizerConfig(
        featConfig: features,
        modelConfig: model,
        enableEndpoint: false,
        decodingMethod: "greedy_search",
        maxActivePaths: 1,
        hotwordsFile: "",
        hotwordsBuf: "",
        hotwordsBufSize: 0
    )
    return SherpaOnnxRecognizer(config: &config)
}

private func transcribe(
    path: String,
    language: String,
    with recognizer: SherpaOnnxRecognizer
) throws -> String {
    let wave = SherpaOnnxWaveWrapper.readWave(filename: path)
    guard wave.wave != nil, wave.numSamples > 0 else {
        throw SmokeTestError.unreadableWave(path)
    }
    recognizer.reset()
    recognizer.setOption(key: "language", value: language)

    let samples = resampleToModelRate(wave.samples, from: wave.sampleRate)
    let feedSize = max(1, Int(Double(sampleRate) * feedDuration))
    var offset = 0
    while offset < samples.count {
        let end = min(offset + feedSize, samples.count)
        recognizer.acceptWaveform(
            samples: Array(samples[offset..<end]),
            sampleRate: sampleRate
        )
        while recognizer.isReady() {
            recognizer.decode()
        }
        offset = end
    }

    recognizer.acceptWaveform(
        samples: [Float](
            repeating: 0,
            count: Int(Double(sampleRate) * finalizationTailDuration)
        ),
        sampleRate: sampleRate
    )
    recognizer.inputFinished()
    while recognizer.isReady() {
        recognizer.decode()
    }

    let text = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw SmokeTestError.emptyTranscript(path) }
    return text
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var language = "auto"
    if arguments.first == "--language" {
        guard arguments.count >= 4 else { throw SmokeTestError.usage }
        language = arguments[1]
        arguments.removeFirst(2)
    }
    guard arguments.count >= 2 else { throw SmokeTestError.usage }

    let modelDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let recognizer = try makeRecognizer(modelDirectory: modelDirectory)
    var failures = 0

    for path in arguments.dropFirst() {
        let start = ContinuousClock.now
        do {
            let transcript = try transcribe(
                path: path,
                language: language,
                with: recognizer
            )
            let elapsed = start.duration(to: .now)
            print("PASS \(URL(fileURLWithPath: path).lastPathComponent) [\(language), \(elapsed)]")
            print(transcript)
        } catch {
            failures += 1
            fputs("FAIL \(path): \(error.localizedDescription)\n", stderr)
        }
    }

    if failures > 0 { exit(EXIT_FAILURE) }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
