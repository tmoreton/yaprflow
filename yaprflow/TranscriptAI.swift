import Combine
import Foundation
import FoundationModels

extension Notification.Name {
    static let yaprflowPromptPresetsChanged = Notification.Name("yaprflow.prompt-presets.changed")
}

@MainActor
final class TranscriptAIModel: ObservableObject {
    static let defaultPrompt = LibraryPromptCatalog.itemDefaultPrompt

    private static let promptKey = "yaprflow.ai.prompt"
    private static let legacyDefaultPrompt = "Summarize this content into concise bullet points. Preserve important details, decisions, names, and follow-up actions."

    @Published var prompt: String {
        didSet {
            UserDefaults.standard.set(prompt, forKey: Self.promptKey)
        }
    }
    @Published var result = ""
    @Published private(set) var isRunning = false
    @Published private(set) var processingMessage: String?
    @Published private(set) var isModelAvailable = false
    @Published private(set) var availabilityMessage = "Checking AI provider…"
    @Published var errorMessage: String?
    private var generationID = UUID()

    init() {
        let storedPrompt = UserDefaults.standard.string(forKey: Self.promptKey)
        if storedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyDefaultPrompt {
            prompt = Self.defaultPrompt
            UserDefaults.standard.set(Self.defaultPrompt, forKey: Self.promptKey)
        } else {
            prompt = storedPrompt ?? Self.defaultPrompt
        }
        refreshAvailability()
    }

    func refreshAvailability() {
        let settings = AIProviderSettings.shared
        if settings.provider != .appleIntelligence {
            isModelAvailable = settings.isConfigured
            if settings.isConfigured {
                availabilityMessage = "Configured for \(settings.provider.displayName) · \(settings.selectedModel)"
            } else if settings.selectedModel.isEmpty {
                availabilityMessage = "Choose a \(settings.provider.displayName) model in Settings."
            } else {
                availabilityMessage = "Add your \(settings.provider.displayName) API key in Settings."
            }
            return
        }

        guard #available(macOS 26.0, *) else {
            isModelAvailable = false
            availabilityMessage = "AI tools require macOS 26 or later."
            return
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            isModelAvailable = true
            availabilityMessage = "Apple Intelligence is ready and runs on this Mac."
        case .unavailable(.deviceNotEligible):
            isModelAvailable = false
            availabilityMessage = "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            isModelAvailable = false
            availabilityMessage = "Turn on Apple Intelligence in System Settings to use AI tools."
        case .unavailable(.modelNotReady):
            isModelAvailable = false
            availabilityMessage = "The on-device model is still downloading or not ready."
        case .unavailable:
            isModelAvailable = false
            availabilityMessage = "Apple Intelligence is not currently available."
        }
    }

    func run(transcript: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        refreshAvailability()
        guard isModelAvailable else { return }
        guard !trimmedPrompt.isEmpty else {
            errorMessage = "Enter a prompt describing what you want the model to do."
            return
        }
        guard !trimmedTranscript.isEmpty else {
            errorMessage = "Select an item with text before running this prompt."
            return
        }

        let provider = AIProviderSettings.shared.provider
        let remoteConfiguration: AIChatConfiguration?
        do {
            remoteConfiguration = provider == .appleIntelligence
                ? nil
                : try AIProviderSettings.shared.configuration()
        } catch {
            errorMessage = Self.message(for: error)
            Telemetry.shared.track(.aiSummaryFailed(provider, Self.telemetryFailure(for: error)))
            return
        }

        let requestID = UUID()
        generationID = requestID
        isRunning = true
        processingMessage = "Preparing source…"
        errorMessage = nil
        Telemetry.shared.track(.aiSummaryStarted(provider))
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generationID == requestID {
                    self.isRunning = false
                    self.processingMessage = nil
                }
            }

            do {
                if provider == .appleIntelligence {
                    if #available(macOS 26.0, *) {
                        let generated = try await TranscriptAIProcessor.generate(
                            prompt: trimmedPrompt,
                            transcript: trimmedTranscript,
                            progress: { progress in
                                guard self.generationID == requestID else { return }
                                self.processingMessage = progress.message
                            }
                        )
                        guard self.generationID == requestID else { return }
                        self.result = generated
                    }
                } else {
                    guard let configuration = remoteConfiguration else {
                        throw AIProviderError.unsupportedProvider
                    }
                    let generated = try await RemoteTranscriptAIProcessor.generate(
                        prompt: trimmedPrompt,
                        transcript: trimmedTranscript,
                        configuration: configuration,
                        progress: {
                            guard self.generationID == requestID else { return }
                            self.processingMessage = $0
                        }
                    )
                    guard self.generationID == requestID else { return }
                    self.result = generated
                }
                guard self.generationID == requestID else { return }
                Telemetry.shared.track(.aiSummaryCompleted(provider))
            } catch {
                guard self.generationID == requestID else { return }
                self.errorMessage = Self.message(for: error)
                Telemetry.shared.track(.aiSummaryFailed(provider, Self.telemetryFailure(for: error)))
            }
        }
    }

    private static func message(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return "The selected model could not process this item. Try again or choose another model."
        }
        return description
    }

    private static func telemetryFailure(for error: Error) -> TelemetryFailure {
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
            case .missingModel, .missingAPIKey, .unsupportedProvider:
                return .provider
            }
        }
        if error is URLError { return .network }
        return .other
    }
}
