import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Grammar")

// MARK: - GitHub Releases Downloader

/// Downloads and extracts the grammar model from GitHub releases (no HuggingFace)
private actor GrammarModelDownloader {
    let releaseURL: URL
    let modelDirName: String
    private var inflight: Task<URL, Error>?

    init(releaseURL: URL, modelDirName: String) {
        self.releaseURL = releaseURL
        self.modelDirName = modelDirName
    }

    /// Returns local directory URL (downloads if needed). Safe to call multiple
    /// times — concurrent calls share a single in-flight download so a silent
    /// `preload()` and a user-triggered `ensureLoaded()` don't fight over the
    /// tarball. Only the first caller's progress handler is honored.
    func downloadIfNeeded(progress: (@MainActor (String) -> Void)? = nil) async throws -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tmoreton.yaprflow/models", isDirectory: true)
        let modelDir = cacheDir.appendingPathComponent(modelDirName, isDirectory: true)

        // Already extracted?
        let configPath = modelDir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configPath.path) {
            return modelDir
        }

        if let inflight = inflight {
            return try await inflight.value
        }

        let releaseURL = self.releaseURL
        let modelDirName = self.modelDirName
        let task = Task<URL, Error> {
            try await Self.performDownload(
                releaseURL: releaseURL,
                cacheDir: cacheDir,
                modelDir: modelDir,
                modelDirName: modelDirName,
                progress: progress
            )
        }
        inflight = task
        do {
            let result = try await task.value
            inflight = nil
            return result
        } catch {
            inflight = nil
            throw error
        }
    }

    private static func performDownload(
        releaseURL: URL,
        cacheDir: URL,
        modelDir: URL,
        modelDirName: String,
        progress: (@MainActor (String) -> Void)?
    ) async throws -> URL {
        let tarballPath = cacheDir.appendingPathComponent("\(modelDirName).tar.gz")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // A previous run may have left a junk tarball behind — e.g. an HTML
        // 404 page persisted as `<name>.tar.gz` because the older code didn't
        // check HTTP status, or a partial download from a killed process. The
        // real tarball is ~750 MB; anything under 50 MB is definitely not it,
        // and trying to tar-extract it just produces the cryptic
        // "Unrecognized archive format" we used to surface to the user.
        if FileManager.default.fileExists(atPath: tarballPath.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: tarballPath.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            if size < 50_000_000 {
                try? FileManager.default.removeItem(at: tarballPath)
            }
        }

        // Download tarball if needed.
        if !FileManager.default.fileExists(atPath: tarballPath.path) {
            let delegate = GrammarDownloadDelegate(progress: progress)
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            let (localURL, response) = try await session.download(from: releaseURL)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                try? FileManager.default.removeItem(at: localURL)
                throw GrammarError.downloadFailed(status: http.statusCode)
            }
            if FileManager.default.fileExists(atPath: tarballPath.path) {
                try? FileManager.default.removeItem(at: tarballPath)
            }
            try FileManager.default.moveItem(at: localURL, to: tarballPath)
        }

        if let progress = progress {
            await MainActor.run { progress("Extracting grammar model…") }
        }

        // Extract.
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try? FileManager.default.removeItem(at: modelDir)
        }
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarballPath.path, "-C", modelDir.path, "--strip-components=1"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Bad tarball — delete it so the next run re-downloads instead of
            // looping forever on the same corrupt file.
            try? FileManager.default.removeItem(at: tarballPath)
            try? FileManager.default.removeItem(at: modelDir)
            throw GrammarError.extractionFailed(stderr)
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tarballPath)

        return modelDir
    }
}

/// Forwards URLSession byte-progress to a MainActor-isolated string callback so
/// the notch overlay can show "Downloading grammar model… 42%" during a fresh
/// install, mirroring the ASR encoder's download UX.
private final class GrammarDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: (@MainActor (String) -> Void)?

    init(progress: (@MainActor (String) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let progress = progress else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let pct = Int((fraction * 100).rounded())
        Task { @MainActor in
            progress("Downloading grammar model… \(pct)%")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Intentionally empty — the awaited `session.download(from:)` returns
        // the temp URL from its return value.
    }
}

// MARK: - Tokenizer Bridge

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

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

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

private struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

// MARK: - Errors

enum GrammarError: LocalizedError {
    case extractionFailed(String)
    case downloadFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let reason): return "Failed to extract model: \(reason)"
        case .downloadFailed(let status): return "Failed to download grammar model (HTTP \(status))"
        }
    }
}

// MARK: - GrammarController

@MainActor
final class GrammarController {
    static let shared = GrammarController()

    private let modelURL = URL(string: "https://github.com/tmoreton/yaprflow/releases/download/v0.1.0-grammar-model/qwen25-1.5b-4bit-mlx.tar.gz")!
    private let modelDirName = "grammar-model-qwen25-1.5b"
    private let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    private var modelContainer: ModelContainer?
    private var idleReleaseTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 300

    private let downloader: GrammarModelDownloader
    private var modelDirectory: URL?

    private let systemPrompt = """
        Fix grammar, spelling, and punctuation. Ensure fragments become \
        complete, standalone sentences that make sense on their own. \
        Preserve meaning and intent. Do not explain. Return only corrected text.
        """

    private let summaryPrompt = """
        Summarize the following text as a coherent paragraph. Capture the \
        main points and key takeaways in flowing prose. Match summary length \
        to input complexity. Do not use bullet points or lists. \
        Do not explain. Return only the summary paragraph.
        """

    private init() {
        self.downloader = GrammarModelDownloader(
            releaseURL: modelURL,
            modelDirName: modelDirName
        )
    }

    /// Downloads model on app launch WITHOUT loading into memory.
    func preload() {
        Task { @MainActor in
            do {
                log.info("Pre-downloading grammar model...")
                modelDirectory = try await downloader.downloadIfNeeded()
                log.info("Grammar model downloaded and ready (not loaded into memory)")
            } catch {
                log.error("Grammar model download failed: \(error.localizedDescription)")
            }
        }
    }

    func correct(text: String, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        let container = try await ensureLoaded(progress: progress)

        let chat: [Chat.Message] = [.system(systemPrompt), .user(text)]
        let input = try await container.prepare(input: UserInput(chat: chat))

        let params = GenerateParameters(maxTokens: 1024, temperature: 0.3, topP: 0.9, topK: 40)
        let stream = try await container.generate(input: input, parameters: params)

        var corrected = ""
        for await generation in stream {
            if case .chunk(let string) = generation { corrected += string }
        }

        corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return text }

        resetIdleTimer()
        return corrected
    }

    func summarize(text: String) async throws -> String {
        let container = try await ensureLoaded()

        let chat: [Chat.Message] = [.system(summaryPrompt), .user(text)]
        let input = try await container.prepare(input: UserInput(chat: chat))

        let params = GenerateParameters(maxTokens: 512, temperature: 0.3, topP: 0.9, topK: 40)
        let stream = try await container.generate(input: input, parameters: params)

        var summary = ""
        for await generation in stream {
            if case .chunk(let string) = generation { summary += string }
        }

        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return text }

        resetIdleTimer()
        return summary
    }

    private func ensureLoaded(progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> ModelContainer {
        if let existing = modelContainer { return existing }

        // Ensure downloaded. The downloader reports its own progress strings
        // ("Downloading grammar model… 42%", "Extracting grammar model…") via
        // the supplied callback so a fresh-install user sees real progress
        // instead of a frozen "Loading grammar model…" for a 788 MB pull.
        if modelDirectory == nil {
            progress("Downloading grammar model… 0%")
            modelDirectory = try await downloader.downloadIfNeeded(progress: progress)
        }

        progress("Loading grammar model…")

        // Load into memory from local directory (this is the expensive part)
        let container = try await loadModelContainer(
            from: modelDirectory!,
            using: TransformersLoader()
        )

        log.info("Grammar model loaded into memory")
        self.modelContainer = container
        resetIdleTimer()
        return container
    }

    private func resetIdleTimer() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(idleTimeout))
            self.modelContainer = nil
            log.info("Grammar model released from memory")
        }
    }
}
