import AVFoundation
import Foundation
import SherpaOnnx

private let modelSampleRate = 16_000

private enum BenchmarkError: LocalizedError {
    case usage
    case missingFile(String)
    case invalidAudio(String)
    case emptyDataset(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: yaprflow-asr-benchmark MODEL MODEL_DIRECTORY DATASET_DIRECTORY [--max-files N] [--output PATH]\n       yaprflow-asr-benchmark --rescore RESULTS.json\nMODEL is nemotron or qwen. DATASET_DIRECTORY is a LibriSpeech subset such as test-clean."
        case .missingFile(let path):
            return "Missing required file: \(path)"
        case .invalidAudio(let path):
            return "Expected 16 kHz mono audio: \(path)"
        case .emptyDataset(let path):
            return "No LibriSpeech audio/transcript pairs found under: \(path)"
        }
    }
}

private struct Sample {
    let fileName: String
    let audioURL: URL
    let reference: String
}

private struct EditStats {
    var insertions = 0
    var deletions = 0
    var substitutions = 0
    var referenceWords = 0

    var errors: Int { insertions + deletions + substitutions }
    var wer: Double {
        referenceWords == 0 ? 0 : Double(errors) / Double(referenceWords)
    }

    static func + (lhs: EditStats, rhs: EditStats) -> EditStats {
        EditStats(
            insertions: lhs.insertions + rhs.insertions,
            deletions: lhs.deletions + rhs.deletions,
            substitutions: lhs.substitutions + rhs.substitutions,
            referenceWords: lhs.referenceWords + rhs.referenceWords
        )
    }
}

private struct Result: Codable {
    let fileName: String
    let hypothesis: String
    let reference: String
    let audioLength: Double
    let processingTime: Double
    let rtfx: Double
    let wer: Double
    let insertions: Int
    let deletions: Int
    let substitutions: Int
    let referenceWords: Int
}

private struct Summary: Codable {
    let files: Int
    let averageWER: Double
    let corpusWER: Double
    let totalErrors: Int
    let totalReferenceWords: Int
    let totalAudioLength: Double
    let totalProcessingTime: Double
    let overallRTFx: Double
}

private struct Report: Codable {
    let model: String
    let results: [Result]
    let summary: Summary
}

private struct ExternalReport: Decodable {
    struct ExternalResult: Decodable {
        let fileName: String
        let hypothesis: String
        let reference: String
        let audioLength: Double?
        let processingTime: Double?
    }

    let results: [ExternalResult]
}

private func normalizedWords(_ text: String) -> [String] {
    let lowered = text.lowercased().precomposedStringWithCompatibilityMapping
    var normalized = ""
    normalized.reserveCapacity(lowered.count)
    for scalar in lowered.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            normalized.unicodeScalars.append(scalar)
        } else {
            normalized.append(" ")
        }
    }
    return normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

private func editStats(hypothesis: String, reference: String) -> EditStats {
    let hypothesisWords = normalizedWords(hypothesis)
    let referenceWords = normalizedWords(reference)
    let rows = hypothesisWords.count + 1
    let columns = referenceWords.count + 1

    struct Cell {
        var distance: Int
        var insertions: Int
        var deletions: Int
        var substitutions: Int
    }

    var matrix = Array(
        repeating: Array(repeating: Cell(distance: 0, insertions: 0, deletions: 0, substitutions: 0), count: columns),
        count: rows
    )
    for row in 1..<rows {
        matrix[row][0] = Cell(distance: row, insertions: row, deletions: 0, substitutions: 0)
    }
    for column in 1..<columns {
        matrix[0][column] = Cell(distance: column, insertions: 0, deletions: column, substitutions: 0)
    }

    if rows > 1, columns > 1 {
        for row in 1..<rows {
            for column in 1..<columns {
                if hypothesisWords[row - 1] == referenceWords[column - 1] {
                    matrix[row][column] = matrix[row - 1][column - 1]
                    continue
                }

                let insertionBase = matrix[row - 1][column]
                let deletionBase = matrix[row][column - 1]
                let substitutionBase = matrix[row - 1][column - 1]
                let candidates = [
                    Cell(
                        distance: insertionBase.distance + 1,
                        insertions: insertionBase.insertions + 1,
                        deletions: insertionBase.deletions,
                        substitutions: insertionBase.substitutions
                    ),
                    Cell(
                        distance: deletionBase.distance + 1,
                        insertions: deletionBase.insertions,
                        deletions: deletionBase.deletions + 1,
                        substitutions: deletionBase.substitutions
                    ),
                    Cell(
                        distance: substitutionBase.distance + 1,
                        insertions: substitutionBase.insertions,
                        deletions: substitutionBase.deletions,
                        substitutions: substitutionBase.substitutions + 1
                    ),
                ]
                matrix[row][column] = candidates.min { left, right in
                    if left.distance != right.distance { return left.distance < right.distance }
                    if left.substitutions != right.substitutions { return left.substitutions < right.substitutions }
                    return left.insertions < right.insertions
                }!
            }
        }
    }

    let final = matrix[rows - 1][columns - 1]
    return EditStats(
        insertions: final.insertions,
        deletions: final.deletions,
        substitutions: final.substitutions,
        referenceWords: referenceWords.count
    )
}

private func collectSamples(from directory: URL, maximum: Int?) throws -> [Sample] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil
    ) else {
        throw BenchmarkError.emptyDataset(directory.path)
    }

    var samples: [Sample] = []
    while let url = enumerator.nextObject() as? URL {
        guard url.lastPathComponent.contains(".trans."), url.pathExtension == "txt" else {
            continue
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            let audioURL = url.deletingLastPathComponent().appendingPathComponent("\(fields[0]).flac")
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
            samples.append(
                Sample(fileName: audioURL.lastPathComponent, audioURL: audioURL, reference: fields[1])
            )
        }
    }

    samples.sort { $0.fileName < $1.fileName }
    if let maximum { samples = Array(samples.prefix(maximum)) }
    guard !samples.isEmpty else { throw BenchmarkError.emptyDataset(directory.path) }
    return samples
}

private func loadAudio(_ url: URL) throws -> [Float] {
    do {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard Int(format.sampleRate.rounded()) == modelSampleRate, format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw BenchmarkError.invalidAudio(url.path)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw BenchmarkError.invalidAudio(url.path)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    } catch {
        // Some macOS builds expose FLAC's compressed processing format through
        // AVAudioFile instead of decoded PCM. The benchmark falls back to the
        // same ffmpeg decoder for every model; decoding time is deliberately
        // outside the measured inference interval.
    }

    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpeg = ffmpegCandidates.first(where: FileManager.default.fileExists(atPath:)) else {
        throw BenchmarkError.invalidAudio(url.path)
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-v", "error", "-i", url.path,
        "-ar", String(modelSampleRate), "-ac", "1",
        "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1",
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
        throw BenchmarkError.invalidAudio(url.path)
    }
    var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return samples
}

private func requireFiles(_ names: [String], under directory: URL) throws {
    for name in names {
        let path = directory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw BenchmarkError.missingFile(path)
        }
    }
}

private func makeNemotronTranscriber(modelDirectory: URL) throws -> ([Float]) -> String {
    try requireFiles(
        ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
        under: modelDirectory
    )
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
    let features = sherpaOnnxFeatureConfig(sampleRate: modelSampleRate, featureDim: 80)
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
    let recognizer = SherpaOnnxRecognizer(config: &config)

    return { samples in
        recognizer.reset()
        recognizer.setOption(key: "language", value: "en-US")
        let feedSize = 5_120
        var offset = 0
        while offset < samples.count {
            let end = min(offset + feedSize, samples.count)
            recognizer.acceptWaveform(samples: Array(samples[offset..<end]), sampleRate: modelSampleRate)
            while recognizer.isReady() { recognizer.decode() }
            offset = end
        }
        recognizer.acceptWaveform(samples: [Float](repeating: 0, count: 20_800), sampleRate: modelSampleRate)
        recognizer.inputFinished()
        while recognizer.isReady() { recognizer.decode() }
        return recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func makeQwenTranscriber(modelDirectory: URL) throws -> ([Float]) -> String {
    try requireFiles(
        ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer/vocab.json"],
        under: modelDirectory
    )
    let qwen = sherpaOnnxOfflineQwen3ASRModelConfig(
        convFrontend: modelDirectory.appendingPathComponent("conv_frontend.onnx").path,
        encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx").path,
        decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx").path,
        tokenizer: modelDirectory.appendingPathComponent("tokenizer", isDirectory: true).path,
        maxTotalLen: 512,
        maxNewTokens: 256
    )
    let model = sherpaOnnxOfflineModelConfig(
        tokens: "",
        numThreads: 2,
        provider: "cpu",
        qwen3Asr: qwen
    )
    let features = sherpaOnnxFeatureConfig(sampleRate: modelSampleRate, featureDim: 80)
    var config = sherpaOnnxOfflineRecognizerConfig(
        featConfig: features,
        modelConfig: model
    )
    let recognizer = SherpaOnnxOfflineRecognizer(config: &config)

    return { samples in
        recognizer.decode(samples: samples, sampleRate: modelSampleRate).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func summarize(_ results: [Result]) -> Summary {
    let averageWER = results.map(\.wer).reduce(0, +) / Double(results.count)
    let combined = results.reduce(EditStats()) { partial, result in
        partial + EditStats(
            insertions: result.insertions,
            deletions: result.deletions,
            substitutions: result.substitutions,
            referenceWords: result.referenceWords
        )
    }
    let totalAudio = results.map(\.audioLength).reduce(0, +)
    let totalProcessing = results.map(\.processingTime).reduce(0, +)
    return Summary(
        files: results.count,
        averageWER: averageWER,
        corpusWER: combined.wer,
        totalErrors: combined.errors,
        totalReferenceWords: combined.referenceWords,
        totalAudioLength: totalAudio,
        totalProcessingTime: totalProcessing,
        overallRTFx: totalProcessing == 0 ? 0 : totalAudio / totalProcessing
    )
}

private func printSummary(_ summary: Summary) {
    print(String(format: "Average clip WER: %.2f%%", summary.averageWER * 100))
    print(String(format: "Corpus WER:       %.2f%% (%d/%d)", summary.corpusWER * 100, summary.totalErrors, summary.totalReferenceWords))
    print(String(format: "Overall speed:    %.1fx real time (%.1fs audio / %.1fs inference)", summary.overallRTFx, summary.totalAudioLength, summary.totalProcessingTime))
}

private func writeReport(_ report: Report, to output: String?) throws {
    guard let output else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
    print("Wrote \(output)")
}

private func rescore(path: String) throws {
    let decoded = try JSONDecoder().decode(
        ExternalReport.self,
        from: Data(contentsOf: URL(fileURLWithPath: path))
    )
    let results = decoded.results.map { result -> Result in
        let stats = editStats(hypothesis: result.hypothesis, reference: result.reference)
        let audio = result.audioLength ?? 0
        let processing = result.processingTime ?? 0
        return Result(
            fileName: result.fileName,
            hypothesis: result.hypothesis,
            reference: result.reference,
            audioLength: audio,
            processingTime: processing,
            rtfx: processing == 0 ? 0 : audio / processing,
            wer: stats.wer,
            insertions: stats.insertions,
            deletions: stats.deletions,
            substitutions: stats.substitutions,
            referenceWords: stats.referenceWords
        )
    }
    printSummary(summarize(results))
}

private func compare(_ specifications: [String]) throws {
    struct ComparedClip {
        let stats: EditStats
        let duration: Double
        let hypothesisIsEmpty: Bool
    }

    var clipsByModel: [String: [String: ComparedClip]] = [:]
    for specification in specifications {
        let fields = specification.split(separator: "=", maxSplits: 1).map(String.init)
        guard fields.count == 2 else { throw BenchmarkError.usage }
        let report = try JSONDecoder().decode(
            ExternalReport.self,
            from: Data(contentsOf: URL(fileURLWithPath: fields[1]))
        )
        var clips = clipsByModel[fields[0], default: [:]]
        for result in report.results {
            let key = result.fileName
            clips[key] = ComparedClip(
                stats: editStats(hypothesis: result.hypothesis, reference: result.reference),
                duration: result.audioLength ?? 0,
                hypothesisIsEmpty: normalizedWords(result.hypothesis).isEmpty
            )
        }
        clipsByModel[fields[0]] = clips
    }

    let labels = clipsByModel.keys.sorted()
    for label in labels {
        let clips = Array(clipsByModel[label, default: [:]].values)
        let combined = clips.reduce(EditStats()) { $0 + $1.stats }
        let average = clips.map { $0.stats.wer }.reduce(0, +) / Double(clips.count)
        let severe = clips.filter { $0.stats.wer >= 0.25 }.count
        let empty = clips.filter(\.hypothesisIsEmpty).count
        let short = clips.filter { $0.duration <= 3 }
        let shortStats = short.reduce(EditStats()) { $0 + $1.stats }
        print(String(format: "%@: %d clips, corpus %.3f%% (%d/%d), average clip %.3f%%, >=25%% WER %d, empty %d, short corpus %.3f%% (%d clips)",
                     label, clips.count, combined.wer * 100, combined.errors, combined.referenceWords,
                     average * 100, severe, empty, shortStats.wer * 100, short.count))
    }

    if labels.count > 1 {
        for leftIndex in 0..<(labels.count - 1) {
            for rightIndex in (leftIndex + 1)..<labels.count {
                let leftLabel = labels[leftIndex]
                let rightLabel = labels[rightIndex]
                let left = clipsByModel[leftLabel, default: [:]]
                let right = clipsByModel[rightLabel, default: [:]]
                let shared = Set(left.keys).intersection(right.keys)
                var leftWins = 0
                var rightWins = 0
                var ties = 0
                for key in shared {
                    let leftErrors = left[key]!.stats.errors
                    let rightErrors = right[key]!.stats.errors
                    if leftErrors < rightErrors { leftWins += 1 }
                    else if rightErrors < leftErrors { rightWins += 1 }
                    else { ties += 1 }
                }
                print("\(leftLabel) vs \(rightLabel): \(leftWins) wins / \(rightWins) wins / \(ties) ties across \(shared.count) shared clips")
            }
        }
    }
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--rescore" {
        guard arguments.count == 2 else { throw BenchmarkError.usage }
        try rescore(path: arguments[1])
        exit(EXIT_SUCCESS)
    }
    if arguments.first == "--compare" {
        guard arguments.count >= 3 else { throw BenchmarkError.usage }
        try compare(Array(arguments.dropFirst()))
        exit(EXIT_SUCCESS)
    }

    guard arguments.count >= 3 else { throw BenchmarkError.usage }
    let modelName = arguments.removeFirst()
    let modelDirectory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    let datasetDirectory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    var maximum: Int?
    var output: String?
    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        guard !arguments.isEmpty else { throw BenchmarkError.usage }
        switch option {
        case "--max-files": maximum = Int(arguments.removeFirst())
        case "--output": output = arguments.removeFirst()
        default: throw BenchmarkError.usage
        }
    }

    let transcribe: ([Float]) -> String
    switch modelName {
    case "nemotron": transcribe = try makeNemotronTranscriber(modelDirectory: modelDirectory)
    case "qwen": transcribe = try makeQwenTranscriber(modelDirectory: modelDirectory)
    default: throw BenchmarkError.usage
    }

    let samples = try collectSamples(from: datasetDirectory, maximum: maximum)
    print("Benchmarking \(modelName) on \(samples.count) files from \(datasetDirectory.lastPathComponent)")
    var results: [Result] = []
    for (index, sample) in samples.enumerated() {
        let audio = try loadAudio(sample.audioURL)
        let start = ContinuousClock.now
        let hypothesis = transcribe(audio)
        let elapsed = start.duration(to: .now)
        let processing = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let duration = Double(audio.count) / Double(modelSampleRate)
        let stats = editStats(hypothesis: hypothesis, reference: sample.reference)
        let result = Result(
            fileName: sample.fileName,
            hypothesis: hypothesis,
            reference: sample.reference,
            audioLength: duration,
            processingTime: processing,
            rtfx: duration / processing,
            wer: stats.wer,
            insertions: stats.insertions,
            deletions: stats.deletions,
            substitutions: stats.substitutions,
            referenceWords: stats.referenceWords
        )
        results.append(result)
        print(String(format: "[%3d/%3d] %@  WER %5.1f%%  %.1fx", index + 1, samples.count, sample.fileName, stats.wer * 100, result.rtfx))
    }

    let summary = summarize(results)
    printSummary(summary)
    try writeReport(Report(model: modelName, results: results, summary: summary), to: output)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
