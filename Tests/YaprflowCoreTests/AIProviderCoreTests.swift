import Foundation
import Testing
@testable import YaprflowCore

@Suite("AI provider requests", .serialized)
struct AIProviderCoreTests {
    @Test("OpenAI sends an authenticated, non-stored chat request")
    func openAIRequest() async throws {
        let session = mockSession { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-openai-key")
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "gpt-4o-mini")
            #expect(body["max_completion_tokens"] as? Int == 120)
            #expect(body["store"] as? Bool == false)
            #expect((body["messages"] as? [[String: String]])?.count == 2)
            return response(for: request, body: """
                {"choices":[{"message":{"content":"Summary ready"},"finish_reason":"stop"}]}
                """)
        }

        let result = try await AIChatClient(session: session).complete(
            configuration: AIChatConfiguration(
                provider: .openAI, model: "gpt-4o-mini", apiKey: "test-openai-key"
            ),
            instructions: "Summarize accurately.",
            prompt: "<transcript>Hello</transcript>",
            maximumResponseTokens: 120
        )
        #expect(result == "Summary ready")
    }

    @Test("OpenRouter uses its endpoint and model slug")
    func openRouterRequest() async throws {
        let session = mockSession { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-router-key")
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "openai/gpt-4o-mini")
            #expect(body["max_tokens"] as? Int == 150)
            return response(for: request, body: """
                {"choices":[{"message":{"content":"Router ready"},"finish_reason":"stop"}]}
                """)
        }

        let result = try await AIChatClient(session: session).complete(
            configuration: AIChatConfiguration(
                provider: .openRouter,
                model: "openai/gpt-4o-mini",
                apiKey: "test-router-key"
            ),
            instructions: "Be brief.",
            prompt: "Hello",
            maximumResponseTokens: 150
        )
        #expect(result == "Router ready")
    }

    @Test("Ollama uses the local chat endpoint without an API key")
    func ollamaRequest() async throws {
        let session = mockSession { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "llama3.2")
            #expect(body["stream"] as? Bool == false)
            #expect((body["options"] as? [String: Int])?["num_predict"] == 90)
            return response(for: request, body: """
                {"message":{"content":"Local ready"},"done":true}
                """)
        }

        let result = try await AIChatClient(session: session).complete(
            configuration: AIChatConfiguration(provider: .ollama, model: "llama3.2"),
            instructions: "Be brief.",
            prompt: "Hello",
            maximumResponseTokens: 90
        )
        #expect(result == "Local ready")
    }

    @Test("Ollama lists installed models")
    func ollamaModels() async throws {
        let session = mockSession { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/api/tags")
            return response(for: request, body: """
                {"models":[{"name":"qwen3:4b"},{"name":"llama3.2"}]}
                """)
        }
        let models = try await AIChatClient(session: session).installedOllamaModels()
        #expect(models == ["llama3.2", "qwen3:4b"])
    }

    @Test("Provider errors are shown without dumping arbitrary response bodies")
    func providerError() async throws {
        let session = mockSession { request in
            response(for: request, status: 401, body: """
                {"error":{"message":"Invalid API key"}}
                """)
        }
        do {
            _ = try await AIChatClient(session: session).complete(
                configuration: AIChatConfiguration(
                    provider: .openAI, model: "gpt-4o-mini", apiKey: "invalid"
                ),
                instructions: "Be brief.",
                prompt: "Hello",
                maximumResponseTokens: 90
            )
            Issue.record("Expected an authentication error")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 401"))
            #expect(error.localizedDescription.contains("Invalid API key"))
        }
    }

    @Test("Ollama's string errors are readable")
    func ollamaError() async throws {
        let session = mockSession { request in
            response(for: request, status: 404, body: #"{"error":"model not found"}"#)
        }
        do {
            _ = try await AIChatClient(session: session).complete(
                configuration: AIChatConfiguration(provider: .ollama, model: "missing"),
                instructions: "Be brief.",
                prompt: "Hello",
                maximumResponseTokens: 90
            )
            Issue.record("Expected a missing model error")
        } catch {
            #expect(error.localizedDescription.contains("model not found"))
        }
    }

    private func mockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(
        for request: URLRequest,
        status: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: AIProviderError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var jsonBody: [String: Any]? {
        var data = httpBody ?? Data()
        if data.isEmpty, let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
