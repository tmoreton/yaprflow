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

    @Test("OpenAI retries a response that exhausts its completion budget")
    func openAIRetriesTruncatedResponse() async throws {
        var requests = 0
        let session = mockSession { request in
            requests += 1
            let body = try #require(request.jsonBody)
            #expect(body["store"] as? Bool == false)
            if requests == 1 {
                #expect(body["max_completion_tokens"] as? Int == 120)
                return response(for: request, body: """
                    {"choices":[{"message":{"content":""},"finish_reason":"length"}]}
                    """)
            }

            #expect(body["max_completion_tokens"] as? Int == 632)
            return response(for: request, body: """
                {"choices":[{"message":{"content":"Complete OpenAI answer"},"finish_reason":"stop"}]}
                """)
        }

        let result = try await AIChatClient(session: session).complete(
            configuration: AIChatConfiguration(
                provider: .openAI,
                model: "gpt-4o-mini",
                apiKey: "test-openai-key"
            ),
            instructions: "Summarize accurately.",
            prompt: "A meeting transcript",
            maximumResponseTokens: 120
        )

        #expect(requests == 2)
        #expect(result == "Complete OpenAI answer")
    }

    @Test("OpenRouter uses its endpoint and model slug")
    func openRouterRequest() async throws {
        let session = mockSession { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-router-key")
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "openai/gpt-4o-mini")
            #expect(body["max_completion_tokens"] as? Int == 150)
            #expect(body["max_tokens"] == nil)
            return response(for: request, body: """
                {"choices":[{"message":{"content":"Router ready","reasoning":"Internal reasoning","reasoning_details":[{"type":"reasoning.text","text":"Internal reasoning"}]},"finish_reason":"stop"}]}
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

    @Test("OpenRouter retries a response that exhausts its completion budget")
    func openRouterRetriesTruncatedResponse() async throws {
        var requests = 0
        let session = mockSession { request in
            requests += 1
            let body = try #require(request.jsonBody)
            if requests == 1 {
                #expect(body["max_completion_tokens"] as? Int == 900)
                return response(for: request, body: """
                    {"choices":[{"message":{"content":""},"finish_reason":"length"}]}
                    """)
            }

            #expect(body["max_completion_tokens"] as? Int == 1_800)
            return response(for: request, body: """
                {"choices":[{"message":{"content":"Complete summary"},"finish_reason":"stop"}]}
                """)
        }

        let result = try await AIChatClient(session: session).complete(
            configuration: AIChatConfiguration(
                provider: .openRouter,
                model: "deepseek/deepseek-v4.1-flash",
                apiKey: "test-router-key"
            ),
            instructions: "Summarize accurately.",
            prompt: "A meeting transcript",
            maximumResponseTokens: 900
        )

        #expect(requests == 2)
        #expect(result == "Complete summary")
    }

    @Test("OpenRouter reports truncation after its bounded retry")
    func openRouterStopsAfterTruncationRetry() async throws {
        var requests = 0
        let session = mockSession { request in
            requests += 1
            return response(for: request, body: """
                {"choices":[{"message":{"content":"Partial"},"finish_reason":"length"}]}
                """)
        }

        do {
            _ = try await AIChatClient(session: session).complete(
                configuration: AIChatConfiguration(
                    provider: .openRouter,
                    model: "deepseek/deepseek-v4.1-flash",
                    apiKey: "test-router-key"
                ),
                instructions: "Summarize accurately.",
                prompt: "A meeting transcript",
                maximumResponseTokens: 900
            )
            Issue.record("Expected a truncation error")
        } catch let error as AIProviderError {
            guard case .truncatedResponse = error else {
                Issue.record("Expected a truncation error, got \(error)")
                return
            }
        }

        #expect(requests == 2)
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
                {"message":{"content":"Local ready","thinking":"Internal reasoning"},"done":true,"done_reason":"stop"}
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

    @Test("Ollama retries when done_reason reports a length limit")
    func ollamaRetriesTruncatedResponse() async throws {
        var requests = 0
        let session = mockSession { request in
            requests += 1
            let body = try #require(request.jsonBody)
            let options = try #require(body["options"] as? [String: Int])
            if requests == 1 {
                #expect(options["num_predict"] == 90)
                return response(for: request, body: """
                    {"message":{"content":""},"done":true,"done_reason":"length"}
                    """)
            }

            #expect(options["num_predict"] == 602)
            return response(for: request, body: """
                {"message":{"content":"Complete local answer"},"done":true,"done_reason":"stop"}
                """)
        }

        let result = try await AIChatClient(session: session).complete(
            configuration: AIChatConfiguration(provider: .ollama, model: "gemma4"),
            instructions: "Be brief.",
            prompt: "Hello",
            maximumResponseTokens: 90
        )

        #expect(requests == 2)
        #expect(result == "Complete local answer")
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
