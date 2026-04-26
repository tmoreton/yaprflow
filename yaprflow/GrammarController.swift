import Foundation
import MLXLLM
import MLXLMCommon
import HuggingFace
import Tokenizers
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Grammar")

/// Bridges HuggingFace.HubClient to MLXLMCommon.Downloader
private struct HubDownloader: MLXLMCommon.Downloader {
    private let upstream: HuggingFace.HubClient

    init(_ upstream: HuggingFace.HubClient = HubClient()) {
        self.upstream = upstream
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw GrammarError.invalidRepositoryID(id)
        }
        let rev = revision ?? "main"
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: rev,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

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

enum GrammarError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid HuggingFace repository ID: \(id)"
        }
    }
}

@MainActor
final class GrammarController {
    static let shared = GrammarController()

    /// Qwen2.5 1.5B 4-bit from mlx-community — no thinking mode, clean output.
    /// Switched from Qwen3 to avoid thinking blocks entirely.
    private let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    private var modelContainer: ModelContainer?
    private var idleReleaseTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 300

    private let systemPrompt = """
        Fix grammar, spelling, and punctuation. Preserve meaning. \
        Do not explain. Return only corrected text.
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
            temperature: 0,
            topP: 1.0,
            topK: 0
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

        // Log for testing/debugging
        log.info("Grammar: '\(text)' -> '\(corrected)'")

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

        progress("Loading grammar model…")

        let config = LLMRegistry.shared.configuration(id: modelID)
        let container = try await loadModelContainer(
            from: HubDownloader(),
            using: TransformersLoader(),
            configuration: config
        )

        log.info("Grammar model loaded: \(self.modelID)")
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
