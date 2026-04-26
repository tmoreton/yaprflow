import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Grammar")

// MARK: - GitHub Releases Downloader

/// Downloads and extracts the grammar model from GitHub releases
private struct GitHubReleasesDownloader: MLXLMCommon.Downloader, @unchecked Sendable {
    let releaseURL: URL
    let modelDirName: String

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // Determine cache location
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tmoreton.yaprflow/models", isDirectory: true)
        let modelDir = cacheDir.appendingPathComponent(modelDirName, isDirectory: true)
        let tarballPath = cacheDir.appendingPathComponent("\(modelDirName).tar.gz")

        // Check if already extracted
        if FileManager.default.fileExists(atPath: modelDir.path) {
            let configPath = modelDir.appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: configPath.path) {
                return modelDir
            }
        }

        // Create cache directory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let progress = Progress(totalUnitCount: 100)

        // Download if not already present
        if !FileManager.default.fileExists(atPath: tarballPath.path) {
            progress.completedUnitCount = 0
            progressHandler(progress)

            let (localURL, _) = try await URLSession.shared.download(from: releaseURL)

            // Move to cache location
            if FileManager.default.fileExists(atPath: tarballPath.path) {
                try FileManager.default.removeItem(at: tarballPath)
            }
            try FileManager.default.moveItem(at: localURL, to: tarballPath)

            progress.completedUnitCount = 50
            progressHandler(progress)
        }

        // Extract if not already done
        return try await extract(tarball: tarballPath, to: modelDir, progress: progress, progressHandler: progressHandler)
    }

    private func extract(
        tarball: URL,
        to destination: URL,
        progress: Progress,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // Remove existing directory if present
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        // Create extraction directory
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Extract tar.gz using tar command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarball.path, "-C", destination.path, "--strip-components=1"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GrammarError.extractionFailed(error)
        }

        // Clean up tarball after successful extraction
        try FileManager.default.removeItem(at: tarball)

        progress.completedUnitCount = 100
        progressHandler(progress)

        return destination
    }
}

// MARK: - Tokenizer Bridge

/// Bridges Tokenizers.Tokenizer to MLXLMCommon.Tokenizer
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads tokenizers from local directories using swift-transformers
private struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    init() {}

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

// MARK: - Errors

enum GrammarError: LocalizedError {
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let reason):
            return "Failed to extract model: \(reason)"
        }
    }
}

// MARK: - GrammarController

@MainActor
final class GrammarController {
    static let shared = GrammarController()

    /// GitHub releases URL for the Qwen2.5-1.5B-4bit model
    private let modelURL = URL(string: "https://github.com/tmoreton/yaprflow/releases/download/v0.1.0-grammar-model/qwen25-1.5b-4bit-mlx.tar.gz")!
    private let modelDirName = "grammar-model-qwen25-1.5b"

    private var modelContainer: ModelContainer?
    private var idleReleaseTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 300

    private let systemPrompt = """
        Fix grammar, spelling, and punctuation. Ensure fragments become \
        complete, standalone sentences that make sense on their own. \
        Preserve meaning and intent. Do not explain. Return only corrected text.
        """

    private init() {}

    func preload() {
        Task { @MainActor in
            _ = try? await ensureLoaded()
        }
    }

    func correct(text: String, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        let container = try await ensureLoaded(progress: progress)

        let chat: [Chat.Message] = [
            .system(systemPrompt),
            .user(text),
        ]
        let userInput = UserInput(chat: chat)

        let input = try await container.prepare(input: userInput)

        let params = GenerateParameters(
            maxTokens: 256,
            temperature: 0.3,
            topP: 0.9,
            topK: 40
        )

        let stream = try await container.generate(input: input, parameters: params)

        var corrected = ""
        for await generation in stream {
            switch generation {
            case .chunk(let string):
                corrected += string
            case .info:
                break
            @unknown default:
                break
            }
        }

        corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        if corrected.isEmpty {
            return text
        }

        resetIdleTimer()
        return corrected
    }

    private func ensureLoaded(progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> ModelContainer {
        if let existing = modelContainer {
            return existing
        }

        progress("Downloading grammar model…")

        let downloader = GitHubReleasesDownloader(
            releaseURL: modelURL,
            modelDirName: modelDirName
        )

        // Use Qwen2.5 configuration from LLMRegistry
        let config = LLMRegistry.shared.configuration(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")

        let container = try await loadModelContainer(
            from: downloader,
            using: TransformersLoader(),
            configuration: config
        )

        log.info("Grammar model loaded from GitHub releases")
        self.modelContainer = container
        resetIdleTimer()
        return container
    }

    private func resetIdleTimer() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(idleTimeout))
            } catch {
                return
            }
            self.modelContainer = nil
            log.info("Grammar model released after idle timeout")
        }
    }
}
