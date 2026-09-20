import Foundation

enum FeedbackKind: String, CaseIterable, Identifiable, Sendable {
    case problem = "Problem"
    case suggestion = "Suggestion"
    case question = "Question"

    var id: Self { self }
}

struct FeedbackDraft: Equatable, Sendable {
    static let recipient = "tim@yaprflow.com"

    let kind: FeedbackKind
    let summary: String
    let details: String
    let version: String
    let build: String
    let operatingSystem: String

    var canCompose: Bool {
        !trimmedSummary.isEmpty && !trimmedDetails.isEmpty
    }

    var emailSubject: String {
        "Yaprflow \(kind.rawValue): \(trimmedSummary)"
    }

    var emailBody: String {
        """
        Type: \(kind.rawValue)
        Summary: \(trimmedSummary)

        \(trimmedDetails)

        ---
        Yaprflow \(version) (\(build))
        \(operatingSystem)
        """
    }

    var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: emailSubject),
            URLQueryItem(name: "body", value: emailBody),
        ]
        return components.url
    }

    private var trimmedSummary: String {
        summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDetails: String {
        details.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TelemetryFeature: String, Sendable {
    case meetingNotes = "meeting_notes"
    case history
    case settings
    case feedback
}

enum TelemetryFailure: String, Sendable {
    case microphone
    case startup
    case clipboard
    case archive
    case audioOverrun = "audio_overrun"
    case noSpeech = "no_speech"
    case microphoneChanged = "microphone_changed"
    case provider
    case authentication
    case rateLimit = "rate_limit"
    case network
    case invalidResponse = "invalid_response"
    case other
}

enum TelemetryEvent: Sendable {
    case appOpened
    case previousRunInterrupted
    case featureOpened(TelemetryFeature)
    case dictationStarted
    case dictationCompleted(durationSeconds: Double)
    case dictationFailed(TelemetryFailure)
    case aiSummaryStarted(AIProviderKind)
    case aiSummaryCompleted(AIProviderKind)
    case aiSummaryFailed(AIProviderKind, TelemetryFailure)
    case archiveTitleFailed(AIProviderKind)
    case feedbackDraftOpened

    var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .previousRunInterrupted: "previous_run_interrupted"
        case .featureOpened: "feature_opened"
        case .dictationStarted: "dictation_started"
        case .dictationCompleted: "dictation_completed"
        case .dictationFailed: "dictation_failed"
        case .aiSummaryStarted: "ai_summary_started"
        case .aiSummaryCompleted: "ai_summary_completed"
        case .aiSummaryFailed: "ai_summary_failed"
        case .archiveTitleFailed: "archive_title_failed"
        case .feedbackDraftOpened: "feedback_draft_opened"
        }
    }

    var properties: [String: String] {
        switch self {
        case .appOpened, .previousRunInterrupted, .dictationStarted, .feedbackDraftOpened:
            [:]
        case let .featureOpened(feature):
            ["feature": feature.rawValue]
        case let .dictationCompleted(seconds):
            ["duration": Self.durationBucket(seconds)]
        case let .dictationFailed(reason):
            ["reason": reason.rawValue]
        case let .aiSummaryStarted(provider), let .aiSummaryCompleted(provider),
             let .archiveTitleFailed(provider):
            ["provider": provider.rawValue]
        case let .aiSummaryFailed(provider, reason):
            ["provider": provider.rawValue, "reason": reason.rawValue]
        }
    }

    private static func durationBucket(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        switch seconds {
        case ..<15: return "under_15s"
        case ..<60: return "15_to_59s"
        case ..<300: return "1_to_4m"
        default: return "5m_or_more"
        }
    }
}

struct AptabaseEndpoint: Sendable {
    let url: URL
    let appKey: String

    init?(appKey: String) {
        let parts = appKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "A", !parts[2].isEmpty,
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        let host: String
        switch parts[1] {
        case "US": host = "us.aptabase.com"
        case "EU": host = "eu.aptabase.com"
        default: return nil
        }
        guard let url = URL(string: "https://\(host)/api/v0/events") else { return nil }
        self.url = url
        self.appKey = appKey
    }
}

struct TelemetryEnvelope: Encodable {
    struct SystemProperties: Encodable {
        let isDebug: Bool
        let locale = "und"
        let osName = "macOS"
        let osVersion: String
        let appVersion: String
        let appBuildNumber: String
        let sdkVersion = "yaprflow-telemetry@1"
        let deviceModel = "Mac"
    }

    let timestamp: Date
    let sessionId: String
    let eventName: String
    let systemProps: SystemProperties
    let props: [String: String]

    init(event: TelemetryEvent, sessionId: String, systemProps: SystemProperties) {
        timestamp = Date()
        self.sessionId = sessionId
        eventName = event.name
        self.systemProps = systemProps
        props = event.properties
    }
}
