import Foundation
import Testing
@testable import YaprflowCore

@Suite("Meeting records and memory")
struct MeetingCoreTests {
    @Test("Transcript preserves speaker labels and timestamps")
    func transcriptFormatting() {
        let meeting = MeetingRecord(
            title: "Design review",
            transcript: [
                MeetingTranscriptSegment(
                    speaker: .me,
                    startTime: 65,
                    endTime: 70,
                    text: "Let's ship the smaller scope."
                ),
            ]
        )

        #expect(meeting.plainTranscript == "[01:05] Me: Let's ship the smaller scope.")
    }

    @Test("Search favors titles and returns exact evidence segments")
    func search() {
        let evidence = MeetingTranscriptSegment(
            speaker: .them,
            startTime: 10,
            endTime: 18,
            text: "The launch date is October fifth."
        )
        let launch = MeetingRecord(title: "Launch planning", transcript: [evidence])
        let unrelated = MeetingRecord(
            title: "Weekly sync",
            rawNotes: "Talk about lunch plans instead."
        )

        let hits = MeetingSearchIndex.search("launch date", in: [unrelated, launch])

        #expect(hits.first?.meetingID == launch.id)
        #expect(hits.contains { $0.segmentID == evidence.id })
        #expect(MeetingSearchIndex.context(for: "launch date", in: [launch]).contains(evidence.id.uuidString))
    }

    @Test("Generated notes discard invented citation identifiers")
    func generatedNotesParsing() throws {
        let validID = UUID()
        let invalidID = UUID()
        let response = """
        ```json
        {"overview":"A useful call","insights":[{"kind":"decision","text":"Ship Friday","owner":null,"dueDate":"Friday","citationSegmentIDs":["\(validID)","\(invalidID)"]}],"followUpEmail":"Thanks"}
        ```
        """

        let notes = try MeetingGeneratedNotesParser.parse(
            response,
            validSegmentIDs: [validID]
        )

        #expect(notes.overview == "A useful call")
        #expect(notes.insights.first?.citationSegmentIDs == [validID])
    }

    @Test("Generation prompt includes human notes and stable evidence IDs")
    func prompt() {
        let segment = MeetingTranscriptSegment(
            speaker: .them,
            startTime: 0,
            endTime: 4,
            text: "Customers need CSV export."
        )
        let meeting = MeetingRecord(
            title: "Research",
            rawNotes: "Important: prioritize export",
            transcript: [segment],
            templateID: "user-research"
        )

        let prompt = MeetingPromptBuilder.generationPrompt(
            for: meeting,
            template: MeetingTemplateCatalog.template(id: meeting.templateID)
        )

        #expect(prompt.contains("Important: prioritize export"))
        #expect(prompt.contains(segment.id.uuidString))
        #expect(prompt.contains("pain points"))
    }

    @Test("Every built-in template has a stable unique identifier")
    func templates() {
        let templates = MeetingTemplateCatalog.builtIns
        #expect(templates.count >= 7)
        #expect(Set(templates.map(\.id)).count == templates.count)
        #expect(MeetingTemplateCatalog.template(id: "missing").id == MeetingTemplateCatalog.generalID)
    }

    @Test("Markdown export retains evidence anchors")
    func markdownExport() {
        let segment = MeetingTranscriptSegment(
            speaker: .me,
            startTime: 75,
            endTime: 80,
            text: "I will send the draft."
        )
        let insight = MeetingInsight(
            kind: .actionItem,
            text: "Send the draft",
            owner: "Me",
            citationSegmentIDs: [segment.id]
        )
        let meeting = MeetingRecord(
            title: "Planning",
            transcript: [segment],
            generatedNotes: MeetingGeneratedNotes(overview: "A plan", insights: [insight])
        )

        let markdown = MeetingMarkdownRenderer.render(meeting)
        #expect(markdown.contains("## Action items"))
        #expect(markdown.contains(segment.id.uuidString))
        #expect(markdown.contains("[01:15]"))
    }

    @Test("Meeting records survive JSON persistence")
    func codableRoundTrip() throws {
        let meeting = MeetingRecord(
            title: "Quarterly planning",
            attendees: [MeetingAttendee(name: "Ari", email: "ari@example.com")],
            rawNotes: "Protect the launch date",
            transcript: [
                MeetingTranscriptSegment(
                    speaker: .them,
                    startTime: 12,
                    endTime: 18,
                    text: "We can ship in October."
                ),
            ],
            templateID: "project-review"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(MeetingRecord.self, from: encoder.encode(meeting))

        #expect(restored.id == meeting.id)
        #expect(restored.title == meeting.title)
        #expect(restored.transcript == meeting.transcript)
        #expect(abs(restored.startedAt.timeIntervalSince(meeting.startedAt)) < 1)
        #expect(restored.attendees.first?.email == "ari@example.com")
    }
}
