import Foundation

enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleIntelligence
    case openAI
    case openRouter
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        }
    }

    var sendsTranscriptOffDevice: Bool {
        self == .openAI || self == .openRouter
    }
}

struct AIChatConfiguration: Sendable {
    let provider: AIProviderKind
    let model: String
    let apiKey: String?

    init(provider: AIProviderKind, model: String, apiKey: String? = nil) {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AIProviderError: LocalizedError {
    case missingModel
    case missingAPIKey
    case unsupportedProvider
    case invalidResponse
    case emptyResponse
    case truncatedResponse
    case httpStatus(Int, String)
    case ollamaUnavailable

    var errorDescription: String? {
        switch self {
        case .missingModel:
            "Choose a model in Settings before running AI Summary."
        case .missingAPIKey:
            "Save an API key for the selected provider in Settings."
        case .unsupportedProvider:
            "This provider cannot be used through the network client."
        case .invalidResponse:
            "The model service returned a response Yaprflow could not read."
        case .emptyResponse:
            "The model returned no text. Try again or choose a different model."
        case .truncatedResponse:
            "The model stopped before finishing its answer. Try a shorter prompt or transcript."
        case let .httpStatus(status, message):
            message.isEmpty ? "The model service returned HTTP \(status)." : "The model service returned HTTP \(status): \(message)"
        case .ollamaUnavailable:
            "Could not reach Ollama. Start Ollama on this Mac and try again."
        }
    }
}

struct AIChatClient {
    static let ollamaBaseURL = URL(string: "http://localhost:11434/api/")!

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func complete(
        configuration: AIChatConfiguration,
        instructions: String,
        prompt: String,
        maximumResponseTokens: Int
    ) async throws -> String {
        guard !configuration.model.isEmpty else { throw AIProviderError.missingModel }

        let messages: [[String: String]] = [
            ["role": "system", "content": instructions],
            ["role": "user", "content": prompt],
        ]
        let url: URL
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": false,
        ]

        switch configuration.provider {
        case .appleIntelligence:
            throw AIProviderError.unsupportedProvider
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            body["max_completion_tokens"] = maximumResponseTokens
            body["store"] = false
        case .openRouter:
            url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            body["max_tokens"] = maximumResponseTokens
        case .ollama:
            url = Self.ollamaBaseURL.appendingPathComponent("chat")
            body["options"] = ["num_predict": maximumResponseTokens]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if configuration.provider == .openAI || configuration.provider == .openRouter {
            guard let key = configuration.apiKey, !key.isEmpty else {
                throw AIProviderError.missingAPIKey
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where configuration.provider == .ollama
            && (error.code == .cannotConnectToHost || error.code == .cannotFindHost
                || error.code == .networkConnectionLost) {
            throw AIProviderError.ollamaUnavailable
        }

        guard let response = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode, Self.serviceError(from: data))
        }

        let result: String
        switch configuration.provider {
        case .openAI, .openRouter:
            guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
                throw AIProviderError.invalidResponse
            }
            guard let choice = decoded.choices.first else { throw AIProviderError.invalidResponse }
            if choice.finishReason == "length" { throw AIProviderError.truncatedResponse }
            result = choice.message.content ?? ""
        case .ollama:
            guard let decoded = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                throw AIProviderError.invalidResponse
            }
            result = decoded.message.content
        case .appleIntelligence:
            throw AIProviderError.unsupportedProvider
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProviderError.emptyResponse }
        return trimmed
    }

    func installedOllamaModels() async throws -> [String] {
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("tags"))
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.ollamaUnavailable
        }
        guard let response = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode, Self.serviceError(from: data))
        }
        guard let decoded = try? JSONDecoder().decode(OllamaModelsResponse.self, from: data) else {
            throw AIProviderError.invalidResponse
        }
        return decoded.models.map(\.name).sorted()
    }

    private static func serviceError(from data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        let detail = object["error"]
        let message = (detail as? [String: Any])?["message"] as? String
            ?? detail as? String
            ?? ""
        // Avoid showing a server's entire response or an echoed prompt in the UI.
        return String(message.prefix(240))
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
}

private struct OllamaModelsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}
