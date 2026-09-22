import Combine
import Foundation
import FoundationModels
import OSLog

/// Processes only newly saved dictations. The exact recognized text remains in
/// the archive and on the clipboard; this appends a separate optional result.
@MainActor
final class AutomaticDictationProcessor: ObservableObject {
    static let shared = AutomaticDictationProcessor()

    private struct Job {
        let url: URL
        let provider: AIProviderKind
        let model: String
        let prompt: String
    }

    @Published private(set) var lastError: String?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tmoreton.yaprflow",
        category: "AutomaticDictation"
    )
    private var jobs: [Job] = []
    private var queuedURLs: Set<URL> = []
    private var isProcessing = false

    private init() {}

    func enqueue(url: URL) {
        let settings = AIProviderSettings.shared
        guard settings.automaticDictationOutput, !queuedURLs.contains(url) else { return }
        let prompt = LibraryPromptPreferences.prompt(
            for: LibraryPromptCatalog.polishedDictation.id
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        queuedURLs.insert(url)
        jobs.append(Job(
            url: url,
            provider: settings.provider,
            model: settings.selectedModel,
            prompt: prompt
        ))
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessing, !jobs.isEmpty else { return }
        isProcessing = true
        let job = jobs.removeFirst()

        Task { [weak self] in
            guard let self else { return }
            defer { self.finish(job) }

            do {
                let settings = AIProviderSettings.shared
                guard settings.automaticDictationOutput,
                      settings.provider == job.provider,
                      settings.selectedModel == job.model else { return }

                let document = try TranscriptArchiveDocument.load(from: job.url)
                guard document.automaticOutput == nil,
                      !document.transcript.isEmpty else { return }

                let output: String
                if job.provider == .appleIntelligence {
                    guard #available(macOS 26.0, *),
                          case .available = SystemLanguageModel.default.availability else {
                        throw AutomaticDictationError.modelUnavailable
                    }
                    output = try await TranscriptAIProcessor.generate(
                        prompt: job.prompt,
                        transcript: document.transcript,
                        progress: { _ in }
                    )
                } else {
                    let configuration = try settings.configuration()
                    guard configuration.provider == job.provider,
                          configuration.model == job.model else { return }
                    output = try await RemoteTranscriptAIProcessor.generate(
                        prompt: job.prompt,
                        transcript: document.transcript,
                        configuration: configuration,
                        progress: { _ in }
                    )
                }

                guard settings.automaticDictationOutput,
                      settings.provider == job.provider,
                      settings.selectedModel == job.model else { return }
                try Self.append(output, to: job.url)
                lastError = nil
                NotificationCenter.default.post(
                    name: .yaprflowTranscriptArchiveChanged,
                    object: TranscriptArchiveChange(oldURL: job.url, newURL: job.url)
                )
            } catch {
                // Never put transcript text or provider request details in logs.
                lastError = "Couldn’t polish the last dictation: \(error.localizedDescription)"
                logger.error("Automatic dictation polishing failed.")
            }
        }
    }

    private func finish(_ job: Job) {
        queuedURLs.remove(job.url)
        isProcessing = false
        processNextIfNeeded()
    }

    private static func append(_ output: String, to url: URL) throws {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AutomaticDictationError.emptyOutput }
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard !contents.contains(TranscriptArchiveDocument.automaticOutputMarker) else { return }
        try (contents.trimmingCharacters(in: .newlines)
            + TranscriptArchiveDocument.automaticOutputMarker
            + trimmed + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum AutomaticDictationError: LocalizedError {
    case emptyOutput
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyOutput: "The selected model returned no polished text."
        case .modelUnavailable: "Apple Intelligence is still loading or unavailable."
        }
    }
}
