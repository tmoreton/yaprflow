import Foundation

enum MeetingAIError: LocalizedError {
    case modelUnavailable
    case noTranscript
    case invalidStructuredResponse

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Configure an AI provider in Settings before generating meeting notes."
        case .noTranscript: "Record some conversation before generating meeting notes."
        case .invalidStructuredResponse: "The AI response could not be read as structured meeting notes. Try generating again."
        }
    }
}

@MainActor
enum MeetingAIService {
    static func generateNotes(
        for meeting: MeetingRecord,
        progress: @escaping (String) -> Void
    ) async throws -> MeetingGeneratedNotes {
        guard !meeting.transcript.isEmpty else { throw MeetingAIError.noTranscript }
        let template = MeetingTemplateCatalog.template(id: meeting.templateID)
        let task = MeetingPromptBuilder.generationInstructions(for: meeting, template: template)
        let source = MeetingPromptBuilder.sourceTranscript(for: meeting)
        let provider = AIProviderSettings.shared.provider
        let tracksRequest = AIProviderSettings.shared.isConfigured
        if tracksRequest { Telemetry.shared.track(.aiSummaryStarted(provider)) }
        let response: String
        do {
            response = try await generate(prompt: task, source: source, progress: progress)
        } catch {
            if tracksRequest {
                Telemetry.shared.track(.aiSummaryFailed(provider, telemetryFailure(for: error)))
            }
            throw error
        }
        do {
            let notes = try MeetingGeneratedNotesParser.parse(
                response,
                validSegmentIDs: Set(meeting.transcript.map(\.id))
            )
            if tracksRequest { Telemetry.shared.track(.aiSummaryCompleted(provider)) }
            return MeetingGeneratedNotesGrounder.grounded(
                notes,
                in: meeting,
                allowsFollowUpDraft: template.includesFollowUpDraft
            )
        } catch {
            if tracksRequest {
                Telemetry.shared.track(.aiSummaryFailed(provider, .invalidResponse))
            }
            throw MeetingAIError.invalidStructuredResponse
        }
    }

    static func answer(
        question: String,
        meeting: MeetingRecord,
        progress: @escaping (String) -> Void
    ) async throws -> String {
        let context = fullContext(for: meeting)
        guard !context.isEmpty else {
            return "I couldn’t find relevant evidence in this meeting."
        }
        let prompt = "Answer the user's question using only the supplied meeting excerpts. Cite claims inline using the exact bracketed meeting and segment references. If the evidence is insufficient, say so.\n\nQuestion: \(question)"
        return try await generate(prompt: prompt, source: context, progress: progress)
    }

    private static func fullContext(for meeting: MeetingRecord) -> String {
        var entries: [String] = []
        if !meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append("[meeting:\(meeting.id.uuidString)] \(meeting.title) — Notes: \(meeting.rawNotes)")
        }
        entries.append(contentsOf: meeting.transcript.map { segment in
            "[meeting:\(meeting.id.uuidString) segment:\(segment.id.uuidString)] \(meeting.title) — \(segment.displaySpeaker): \(segment.text)"
        })
        return entries.joined(separator: "\n")
    }

    private static func generate(
        prompt: String,
        source: String,
        progress: @escaping (String) -> Void
    ) async throws -> String {
        let settings = AIProviderSettings.shared
        guard settings.isConfigured else { throw MeetingAIError.modelUnavailable }

        if settings.provider == .appleIntelligence {
            guard #available(macOS 26.0, *) else { throw MeetingAIError.modelUnavailable }
            return try await TranscriptAIProcessor.generate(
                prompt: prompt,
                transcript: source,
                progress: { progress($0.message) }
            )
        }

        return try await RemoteTranscriptAIProcessor.generate(
            prompt: prompt,
            transcript: source,
            configuration: try settings.configuration(),
            progress: progress
        )
    }

    private static func telemetryFailure(for error: Error) -> TelemetryFailure {
        if error is DecodingError {
            return .invalidResponse
        }
        if let providerError = error as? AIProviderError {
            switch providerError {
            case let .httpStatus(status, _):
                if status == 401 || status == 403 { return .authentication }
                if status == 429 { return .rateLimit }
                return .provider
            case .invalidResponse, .emptyResponse, .truncatedResponse:
                return .invalidResponse
            case .ollamaUnavailable:
                return .network
            case .missingModel, .missingAPIKey, .unsupportedProvider, .invalidEndpoint:
                return .provider
            }
        }
        if error is URLError { return .network }
        return .other
    }
}
