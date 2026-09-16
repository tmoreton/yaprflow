import Foundation
import Testing
@testable import YaprflowCore

@Suite("Anonymous telemetry payloads")
struct TelemetryCoreTests {
    @Test("Only managed Aptabase regions are accepted")
    func endpoint() {
        #expect(AptabaseEndpoint(appKey: "A-US-abc123")?.url.absoluteString
                == "https://us.aptabase.com/api/v0/events")
        #expect(AptabaseEndpoint(appKey: "A-EU-abc123")?.url.absoluteString
                == "https://eu.aptabase.com/api/v0/events")
        #expect(AptabaseEndpoint(appKey: "A-US-") == nil)
        #expect(AptabaseEndpoint(appKey: "A-SH-abc123") == nil)
        #expect(AptabaseEndpoint(appKey: "A-US-abc\nInjected") == nil)
        #expect(AptabaseEndpoint(appKey: "A-US-abc١٢٣") == nil)
    }

    @Test("Dictation duration is bucketed, and events have fixed properties")
    func eventProperties() {
        #expect(TelemetryEvent.dictationCompleted(durationSeconds: 72).properties
                == ["duration": "1_to_4m"])
        #expect(TelemetryEvent.dictationFailed(.microphone).properties
                == ["reason": "microphone"])
        #expect(TelemetryEvent.aiSummaryFailed(.openRouter, .provider).properties
                == ["provider": "openRouter", "reason": "provider"])
        #expect(TelemetryEvent.aiSummaryFailed(.openAI, .rateLimit).properties
                == ["provider": "openAI", "reason": "rate_limit"])
        #expect(TelemetryEvent.feedbackDraftOpened.properties.isEmpty)
        #expect(TelemetryEvent.previousRunInterrupted.properties.isEmpty)
    }

    @Test("Encoded events contain only the reviewed fields")
    func payloadFields() throws {
        let properties = TelemetryEnvelope.SystemProperties(
            isDebug: false,
            osVersion: "14.7",
            appVersion: "5.0.1",
            appBuildNumber: "5"
        )
        let payload = TelemetryEnvelope(
            event: .dictationFailed(.archive),
            sessionId: "12345678901234567",
            systemProps: properties
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["timestamp", "sessionId", "eventName", "systemProps", "props"])
        #expect(object["eventName"] as? String == "dictation_failed")
        #expect(object["props"] as? [String: String] == ["reason": "archive"])
        let system = try #require(object["systemProps"] as? [String: Any])
        #expect(system["deviceModel"] as? String == "Mac")
        #expect(system["locale"] as? String == "und")
    }
}
