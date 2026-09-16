import Combine
import Foundation
import OSLog

@MainActor
final class Telemetry: ObservableObject {
    static let shared = Telemetry()

    private static let preferenceKey = "yaprflow.telemetry.enabled"
    private static let runOpenKey = "yaprflow.telemetry.runOpen"
    private let logger = Logger(subsystem: "com.tmoreton.yaprflow", category: "Telemetry")
    private let endpoint: AptabaseEndpoint?
    private let session: URLSession
    private var sessionId: String
    private var lastActivityAt = Date()
    private let systemProperties: TelemetryEnvelope.SystemProperties
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var didTrackOpen = false
    private var hasMarkedRun = false

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            if isEnabled {
                beginRun()
            } else {
                for task in pending.values { task.cancel() }
                pending.removeAll()
                endRun()
            }
        }
    }

    var isConfigured: Bool { endpoint != nil }

    private init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "AptabaseAppKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredEndpoint = AptabaseEndpoint(appKey: key)
        endpoint = configuredEndpoint
        isEnabled = configuredEndpoint != nil &&
            (UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        sessionId = Self.makeSessionId(at: Date())
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemProperties = TelemetryEnvelope.SystemProperties(
            isDebug: Self.isDebugBuild,
            osVersion: "\(os.majorVersion).\(os.minorVersion)",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    func beginRun() {
        guard isEnabled, isConfigured, !hasMarkedRun else { return }
        let previousRunWasOpen = UserDefaults.standard.bool(forKey: Self.runOpenKey)
        UserDefaults.standard.set(true, forKey: Self.runOpenKey)
        hasMarkedRun = true
        track(.appOpened)
        if previousRunWasOpen { track(.previousRunInterrupted) }
    }

    func endRun() {
        guard hasMarkedRun else { return }
        UserDefaults.standard.set(false, forKey: Self.runOpenKey)
        hasMarkedRun = false
    }

    func track(_ event: TelemetryEvent) {
        guard isEnabled, let endpoint, pending.count < 25 else { return }
        if case .appOpened = event {
            guard !didTrackOpen else { return }
            didTrackOpen = true
        }
        let now = Date()
        if now.timeIntervalSince(lastActivityAt) >= 3_600 {
            sessionId = Self.makeSessionId(at: now)
        }
        lastActivityAt = now
        let envelope = TelemetryEnvelope(
            event: event,
            sessionId: sessionId,
            systemProps: systemProperties
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode([envelope]) else { return }

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.appKey, forHTTPHeaderField: "App-Key")
        request.httpBody = body

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, self.isEnabled, !Task.isCancelled else { return }
            defer { self.pending.removeValue(forKey: id) }
            do {
                let (_, response) = try await self.session.data(for: request)
                if let response = response as? HTTPURLResponse,
                   !(200..<300).contains(response.statusCode) {
                    self.logger.error("Telemetry request failed with HTTP \(response.statusCode)")
                }
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Telemetry request failed")
                }
            }
        }
        pending[id] = task
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func makeSessionId(at date: Date) -> String {
        let seconds = UInt64(date.timeIntervalSince1970)
        return String(seconds * 100_000_000 + UInt64.random(in: 0...99_999_999))
    }
}
