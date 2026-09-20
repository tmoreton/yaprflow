import Foundation
import Testing
@testable import YaprflowCore

@Suite("Feedback drafts")
struct FeedbackCoreTests {
    @Test("Drafts require a summary and details after trimming")
    func validation() {
        #expect(!makeDraft(summary: "", details: "Details").canCompose)
        #expect(!makeDraft(summary: "Summary", details: "  \n ").canCompose)
        #expect(makeDraft(summary: "  Summary  ", details: "  Details  ").canCompose)
    }

    @Test("Drafts contain the selected type and diagnostic versions")
    func content() {
        let draft = makeDraft(
            kind: .suggestion,
            summary: "  Better notes  ",
            details: "  Add owners & dates.  "
        )

        #expect(draft.emailSubject == "Yaprflow Suggestion: Better notes")
        #expect(draft.emailBody.contains("Type: Suggestion"))
        #expect(draft.emailBody.contains("Summary: Better notes"))
        #expect(draft.emailBody.contains("Add owners & dates."))
        #expect(draft.emailBody.contains("Yaprflow 5.2.0 (13)"))
        #expect(draft.emailBody.contains("Test OS 1.0"))
    }

    @Test("Mail links safely encode punctuation and newlines")
    func mailtoURL() throws {
        let draft = makeDraft(
            summary: "Audio & notes?",
            details: "First line\nSecond line + follow-up"
        )
        let url = try #require(draft.mailtoURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })

        #expect(components.scheme == "mailto")
        #expect(components.path == FeedbackDraft.recipient)
        #expect(query["subject"] == draft.emailSubject)
        #expect(query["body"] == draft.emailBody)
    }

    private func makeDraft(
        kind: FeedbackKind = .problem,
        summary: String,
        details: String
    ) -> FeedbackDraft {
        FeedbackDraft(
            kind: kind,
            summary: summary,
            details: details,
            version: "5.2.0",
            build: "13",
            operatingSystem: "Test OS 1.0"
        )
    }
}
