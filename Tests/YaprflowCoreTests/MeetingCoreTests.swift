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

    @Test("System playback is removed from overlapping microphone text")
    func systemAudioEchoReconciliation() {
        let systemText = "Jalen you are surgical on that final drive just what allows you to stay so poised in those situations"
        let segments = [
            MeetingTranscriptSegment(
                speaker: .me,
                startTime: 0,
                endTime: 25,
                text: "Hello hello hello how you doing today my name is Tim \(systemText)"
            ),
            MeetingTranscriptSegment(
                speaker: .them,
                startTime: 1,
                endTime: 24,
                text: systemText
            ),
        ]

        let reconciled = MeetingTranscriptReconciler.reconcile(segments)

        #expect(reconciled.count == 2)
        #expect(reconciled.first { $0.speaker == .me }?.text == "Hello hello hello how you doing today my name is Tim")
        #expect(reconciled.first { $0.speaker == .them }?.text == systemText)
    }

    @Test("Distinct or non-overlapping speech is preserved")
    func preservesDistinctSpeech() {
        let microphone = MeetingTranscriptSegment(
            speaker: .me,
            startTime: 0,
            endTime: 5,
            text: "We should review the launch plan tomorrow morning"
        )
        let laterSystemAudio = MeetingTranscriptSegment(
            speaker: .them,
            startTime: 20,
            endTime: 25,
            text: "We should review the launch plan tomorrow morning"
        )

        let reconciled = MeetingTranscriptReconciler.reconcile([microphone, laterSystemAudio])

        #expect(reconciled.map(\.text) == [microphone.text, laterSystemAudio.text])
    }

    @Test("Transcript display puts the most recent speech first")
    func newestTranscriptFirst() {
        let older = MeetingTranscriptSegment(
            speaker: .them,
            startTime: 4,
            endTime: 8,
            text: "Older message"
        )
        let newer = MeetingTranscriptSegment(
            speaker: .me,
            startTime: 40,
            endTime: 44,
            text: "Newer message"
        )

        #expect(MeetingTranscriptReconciler.newestFirst([older, newer]).map(\.id) == [newer.id, older.id])
    }

    @Test("Long meeting timestamps retain hours")
    func timestampFormatting() {
        #expect(MeetingTranscriptTimestamp.string(for: 0) == "00:00")
        #expect(MeetingTranscriptTimestamp.string(for: 65.9) == "01:05")
        #expect(MeetingTranscriptTimestamp.string(for: 3_661) == "1:01:01")
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
        {"title":"Friday Launch Decision","overview":"A useful call","insights":[{"kind":"decision","text":"Ship Friday","owner":null,"dueDate":"Friday","citationSegmentIDs":["\(validID)","\(invalidID)"]}],"followUpEmail":"Thanks"}
        ```
        """

        let notes = try MeetingGeneratedNotesParser.parse(
            response,
            validSegmentIDs: [validID]
        )

        #expect(notes.suggestedTitle == "Friday Launch Decision")
        #expect(notes.overview == "A useful call")
        #expect(notes.insights.first?.citationSegmentIDs == [validID])
    }

    @Test("Only generic meeting names are replaced by generated titles")
    func generatedTitleEligibility() {
        #expect(MeetingRecord(title: "New meeting").needsGeneratedTitle)
        #expect(MeetingRecord(title: "  ").needsGeneratedTitle)
        #expect(!MeetingRecord(title: "Weekly product review").needsGeneratedTitle)
    }

    @Test("Generated notes tolerate common model JSON variations")
    func generatedNotesFlexibleJSONParsing() throws {
        let validID = UUID()
        let response = """
        {
          "summary": "The team aligned on the launch.",
          "action_items": [
            {
              "type": "next_step",
              "action": "Send the revised plan",
              "assignee": "Taylor",
              "deadline": "Friday",
              "citations": ["\(validID)"]
            }
          ],
        }
        """

        let notes = try MeetingGeneratedNotesParser.parse(
            response,
            validSegmentIDs: [validID]
        )

        #expect(notes.overview == "The team aligned on the launch.")
        #expect(notes.insights.first?.kind == .actionItem)
        #expect(notes.insights.first?.text == "Send the revised plan")
        #expect(notes.insights.first?.owner == "Taylor")
        #expect(notes.insights.first?.dueDate == "Friday")
        #expect(notes.insights.first?.citationSegmentIDs == [validID])
        #expect(notes.followUpEmail.isEmpty)
    }

    @Test("Generated notes preserve useful Markdown when a model ignores JSON")
    func generatedNotesMarkdownFallback() throws {
        let validID = UUID()
        let response = """
        ## Summary
        The launch plan was reviewed.

        ## Decisions
        - Ship the smaller scope [\(validID)]

        ## Action items
        - Send the revised plan by Friday.

        ## Follow-up email
        Thanks for aligning on the launch plan.
        """

        let notes = try MeetingGeneratedNotesParser.parse(
            response,
            validSegmentIDs: [validID]
        )

        #expect(notes.overview == "The launch plan was reviewed.")
        #expect(notes.insights.contains { $0.kind == .decision && $0.citationSegmentIDs == [validID] })
        #expect(notes.insights.contains { $0.kind == .actionItem && $0.text == "Send the revised plan by Friday." })
        #expect(notes.followUpEmail == "Thanks for aligning on the launch plan.")
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

    @Test("Library presets provide structured, trustworthy workflows")
    func libraryPromptPresets() {
        let presets = LibraryPromptCatalog.itemPresets + LibraryPromptCatalog.allMeetingPresets

        #expect(presets.count == 8)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.allSatisfy { $0.prompt.split(separator: "\n").count >= 8 })
        #expect(presets.allSatisfy { $0.prompt.localizedCaseInsensitiveContains("invent") })
        #expect(LibraryPromptCatalog.itemPresets.contains { $0.id == "follow-up-email" })
        #expect(LibraryPromptCatalog.allMeetingPresets.contains { $0.id == "follow-up-queue" })
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
