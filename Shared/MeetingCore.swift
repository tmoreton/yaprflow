import Foundation
import NaturalLanguage

public enum MeetingSpeaker: String, Codable, CaseIterable, Sendable {
    case me
    case them
    case unknown

    public var displayName: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        case .unknown: "Speaker"
        }
    }
}

public struct MeetingTranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var speaker: MeetingSpeaker
    public var speakerName: String?
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(
        id: UUID = UUID(),
        speaker: MeetingSpeaker,
        speakerName: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speaker = speaker
        self.speakerName = speakerName
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var displaySpeaker: String {
        let trimmed = speakerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? speaker.displayName : trimmed
    }
}

public struct MeetingAttendee: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var email: String?

    public init(id: UUID = UUID(), name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}

public enum MeetingInsightKind: String, Codable, CaseIterable, Sendable {
    case summary
    case decision
    case actionItem
    case openQuestion
    case keyDetail

    public var displayName: String {
        switch self {
        case .summary: "Key points"
        case .decision: "Decisions"
        case .actionItem: "Action items"
        case .openQuestion: "Open questions"
        case .keyDetail: "Key details"
        }
    }
}

public struct MeetingInsight: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: MeetingInsightKind
    public var text: String
    public var owner: String?
    public var dueDate: String?
    public var citationSegmentIDs: [UUID]

    public init(
        id: UUID = UUID(),
        kind: MeetingInsightKind,
        text: String,
        owner: String? = nil,
        dueDate: String? = nil,
        citationSegmentIDs: [UUID] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = owner
        self.dueDate = dueDate
        self.citationSegmentIDs = citationSegmentIDs
    }
}

public struct MeetingGeneratedNotes: Codable, Hashable, Sendable {
    public var overview: String
    public var insights: [MeetingInsight]
    public var followUpEmail: String
    public var generatedAt: Date

    public init(
        overview: String = "",
        insights: [MeetingInsight] = [],
        followUpEmail: String = "",
        generatedAt: Date = Date()
    ) {
        self.overview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        self.insights = insights.filter { !$0.text.isEmpty }
        self.followUpEmail = followUpEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.generatedAt = generatedAt
    }
}

public struct MeetingRecord: Codable, Identifiable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public let id: UUID
    public var title: String
    public var calendarEventIdentifier: String?
    public var recurrenceIdentifier: String?
    public var scheduledStart: Date?
    public var scheduledEnd: Date?
    public var startedAt: Date
    public var endedAt: Date?
    public var attendees: [MeetingAttendee]
    public var rawNotes: String
    public var transcript: [MeetingTranscriptSegment]
    public var templateID: String
    public var generatedNotes: MeetingGeneratedNotes?

    public init(
        version: Int = MeetingRecord.currentVersion,
        id: UUID = UUID(),
        title: String,
        calendarEventIdentifier: String? = nil,
        recurrenceIdentifier: String? = nil,
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        attendees: [MeetingAttendee] = [],
        rawNotes: String = "",
        transcript: [MeetingTranscriptSegment] = [],
        templateID: String = MeetingTemplateCatalog.generalID,
        generatedNotes: MeetingGeneratedNotes? = nil
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.calendarEventIdentifier = calendarEventIdentifier
        self.recurrenceIdentifier = recurrenceIdentifier
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attendees = attendees
        self.rawNotes = rawNotes
        self.transcript = transcript
        self.templateID = templateID
        self.generatedNotes = generatedNotes
    }

    public var plainTranscript: String {
        transcript.map { segment in
            "[\(Self.timestamp(segment.startTime))] \(segment.displaySpeaker): \(segment.text)"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

public struct MeetingTemplate: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var systemImage: String
    public var instructions: String

    public init(id: String, name: String, systemImage: String, instructions: String) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.instructions = instructions
    }
}

public enum MeetingTemplateCatalog {
    public static let generalID = "general"

    public static let builtIns: [MeetingTemplate] = [
        MeetingTemplate(
            id: generalID,
            name: "General meeting",
            systemImage: "person.2",
            instructions: "Capture the main points, decisions, action items, key details, and unresolved questions."
        ),
        MeetingTemplate(
            id: "one-to-one",
            name: "1:1",
            systemImage: "person.line.dotted.person",
            instructions: "Emphasize updates, feedback, coaching topics, commitments, and topics to revisit next time."
        ),
        MeetingTemplate(
            id: "interview",
            name: "Interview",
            systemImage: "person.crop.rectangle",
            instructions: "Organize evidence by question, strengths, concerns, concrete examples, and recommended next step."
        ),
        MeetingTemplate(
            id: "user-research",
            name: "User research",
            systemImage: "quote.bubble",
            instructions: "Capture user goals, current workflow, pain points, verbatim evidence, feature requests, and opportunities."
        ),
        MeetingTemplate(
            id: "sales",
            name: "Sales call",
            systemImage: "chart.line.uptrend.xyaxis",
            instructions: "Capture needs, qualification signals, objections, stakeholders, timing, pricing discussion, and next steps."
        ),
        MeetingTemplate(
            id: "standup",
            name: "Standup",
            systemImage: "figure.stand",
            instructions: "Organize updates by person or workstream, then list blockers, decisions, and today's commitments."
        ),
        MeetingTemplate(
            id: "project-review",
            name: "Project review",
            systemImage: "checklist",
            instructions: "Capture status, milestones, risks, dependencies, decisions, owners, and target dates."
        ),
    ]

    public static func template(id: String) -> MeetingTemplate {
        builtIns.first { $0.id == id } ?? builtIns[0]
    }
}

public struct MeetingSearchHit: Identifiable, Hashable, Sendable {
    public let meetingID: UUID
    public let segmentID: UUID?
    public let title: String
    public let excerpt: String
    public let score: Int

    public var id: String {
        "\(meetingID.uuidString):\(segmentID?.uuidString ?? "meeting")"
    }
}

public enum MeetingSearchIndex {
    public static func search(
        _ query: String,
        in meetings: [MeetingRecord],
        limit: Int = 20
    ) -> [MeetingSearchHit] {
        let terms = tokens(in: query)
        guard !terms.isEmpty, limit > 0 else { return [] }

        var hits: [MeetingSearchHit] = []
        for meeting in meetings {
            let titleTokens = tokens(in: meeting.title)
            let noteTokens = tokens(in: meeting.rawNotes)
            let attendeeTokens = tokens(in: meeting.attendees.map(\.name).joined(separator: " "))
            let meetingScore = weightedMatches(terms, in: titleTokens, weight: 8)
                + weightedMatches(terms, in: attendeeTokens, weight: 5)
                + weightedMatches(terms, in: noteTokens, weight: 3)
            if meetingScore > 0 {
                hits.append(MeetingSearchHit(
                    meetingID: meeting.id,
                    segmentID: nil,
                    title: meeting.title,
                    excerpt: excerpt(from: meeting.rawNotes, matching: terms),
                    score: meetingScore
                ))
            }

            for segment in meeting.transcript {
                let lexicalScore = weightedMatches(terms, in: tokens(in: segment.text), weight: 2)
                let semanticScore = semanticSimilarity(query, segment.text)
                    .map { Int(max(0, ($0 - 0.35) * 20)) } ?? 0
                let score = lexicalScore + semanticScore
                guard score > 0 else { continue }
                hits.append(MeetingSearchHit(
                    meetingID: meeting.id,
                    segmentID: segment.id,
                    title: meeting.title,
                    excerpt: "\(segment.displaySpeaker): \(excerpt(from: segment.text, matching: terms))",
                    score: score + meetingScore
                ))
            }
        }

        return hits.sorted {
            if $0.score == $1.score { return $0.title < $1.title }
            return $0.score > $1.score
        }.prefix(limit).map { $0 }
    }

    public static func context(
        for query: String,
        in meetings: [MeetingRecord],
        maximumSegments: Int = 30
    ) -> String {
        let meetingByID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        return search(query, in: meetings, limit: maximumSegments).compactMap { hit in
            guard let meeting = meetingByID[hit.meetingID] else { return nil }
            if let segmentID = hit.segmentID,
               let segment = meeting.transcript.first(where: { $0.id == segmentID }) {
                return "[meeting:\(meeting.id.uuidString) segment:\(segment.id.uuidString)] \(meeting.title) — \(segment.displaySpeaker): \(segment.text)"
            }
            return "[meeting:\(meeting.id.uuidString)] \(meeting.title) — Notes: \(meeting.rawNotes)"
        }.joined(separator: "\n")
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    private static func weightedMatches(_ query: [String], in content: [String], weight: Int) -> Int {
        let contentSet = Set(content)
        return query.reduce(into: 0) { score, term in
            if contentSet.contains(term) {
                score += weight * 2
            } else if content.contains(where: { $0.hasPrefix(term) || term.hasPrefix($0) }) {
                score += weight
            }
        }
    }

    /// Apple's sentence embedding keeps meeting-memory retrieval local while
    /// allowing related wording (for example "ship" and "launch") to match.
    private static func semanticSimilarity(_ lhs: String, _ rhs: String) -> Double? {
        guard lhs.count >= 3, rhs.count >= 3,
              let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let lhsVector = embedding.vector(for: lhs),
              let rhsVector = embedding.vector(for: rhs),
              lhsVector.count == rhsVector.count else {
            return nil
        }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhsVector.indices {
            dot += lhsVector[index] * rhsVector[index]
            lhsMagnitude += lhsVector[index] * lhsVector[index]
            rhsMagnitude += rhsVector[index] * rhsVector[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }

    private static func excerpt(from text: String, matching terms: [String]) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > 180 else { return compact }
        let lower = compact.lowercased()
        let match = terms.compactMap { lower.range(of: $0)?.lowerBound }.min()
        let center = match.map { lower.distance(from: lower.startIndex, to: $0) } ?? 0
        let startOffset = max(0, min(compact.count - 180, center - 50))
        let start = compact.index(compact.startIndex, offsetBy: startOffset)
        let end = compact.index(start, offsetBy: min(180, compact.distance(from: start, to: compact.endIndex)))
        return (startOffset > 0 ? "…" : "") + compact[start..<end] + (end < compact.endIndex ? "…" : "")
    }
}

public enum MeetingPromptBuilder {
    public static func generationPrompt(for meeting: MeetingRecord, template: MeetingTemplate) -> String {
        generationInstructions(for: meeting, template: template)
            + "\n\n<transcript>\n"
            + sourceTranscript(for: meeting)
            + "\n</transcript>"
    }

    public static func generationInstructions(for meeting: MeetingRecord, template: MeetingTemplate) -> String {
        let attendeeList = meeting.attendees.map(\.name).joined(separator: ", ")
        return """
        Create trustworthy meeting notes using the template guidance below.
        Never invent a fact, owner, date, or decision. Prefer the user's raw notes when they emphasize a topic.
        Every insight must cite one or more exact transcript segment UUIDs.

        Template: \(template.name)
        Guidance: \(template.instructions)
        Meeting title: \(meeting.title)
        Attendees: \(attendeeList.isEmpty ? "Not provided" : attendeeList)

        <raw-notes>
        \(meeting.rawNotes)
        </raw-notes>

        Return only JSON with this shape:
        {"overview":"...","insights":[{"kind":"summary|decision|actionItem|openQuestion|keyDetail","text":"...","owner":null,"dueDate":null,"citationSegmentIDs":["UUID"]}],"followUpEmail":"..."}
        """
    }

    public static func sourceTranscript(for meeting: MeetingRecord) -> String {
        meeting.transcript.map { segment in
            "<segment id=\"\(segment.id.uuidString)\" time=\"\(Int(segment.startTime))\" speaker=\"\(segment.displaySpeaker)\">\(segment.text)</segment>"
        }.joined(separator: "\n")
    }

    public static func questionPrompt(question: String, context: String) -> String {
        """
        Answer the question using only the meeting excerpts below. Cite claims inline with their bracketed meeting/segment references. If the excerpts do not answer it, say so.

        Question: \(question)

        <meeting-excerpts>
        \(context)
        </meeting-excerpts>
        """
    }
}

public enum MeetingGeneratedNotesParser {
    private struct Payload: Decodable {
        struct Insight: Decodable {
            let kind: MeetingInsightKind
            let text: String
            let owner: String?
            let dueDate: String?
            let citationSegmentIDs: [UUID]
        }

        let overview: String
        let insights: [Insight]
        let followUpEmail: String
    }

    public static func parse(_ response: String, validSegmentIDs: Set<UUID>) throws -> MeetingGeneratedNotes {
        let json = extractedJSONObject(from: response)
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        let insights = payload.insights.map { item in
            MeetingInsight(
                kind: item.kind,
                text: item.text,
                owner: item.owner,
                dueDate: item.dueDate,
                citationSegmentIDs: item.citationSegmentIDs.filter(validSegmentIDs.contains)
            )
        }
        return MeetingGeneratedNotes(
            overview: payload.overview,
            insights: insights,
            followUpEmail: payload.followUpEmail
        )
    }

    private static func extractedJSONObject(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first <= last else { return trimmed }
        return String(trimmed[first...last])
    }
}

public enum MeetingMarkdownRenderer {
    public static func render(_ meeting: MeetingRecord) -> String {
        var sections: [String] = [
            "# \(meeting.title)",
            "",
            "Started: \(meeting.startedAt.formatted(date: .long, time: .shortened))",
        ]

        if !meeting.attendees.isEmpty {
            sections.append("Attendees: \(meeting.attendees.map(\.name).joined(separator: ", "))")
        }

        if let generated = meeting.generatedNotes {
            sections.append(contentsOf: ["", "## Overview", "", generated.overview])
            for kind in MeetingInsightKind.allCases {
                let insights = generated.insights.filter { $0.kind == kind }
                guard !insights.isEmpty else { continue }
                sections.append(contentsOf: ["", "## \(kind.displayName)", ""])
                for insight in insights {
                    var suffix: [String] = []
                    if let owner = insight.owner, !owner.isEmpty { suffix.append("Owner: \(owner)") }
                    if let dueDate = insight.dueDate, !dueDate.isEmpty { suffix.append("Due: \(dueDate)") }
                    if !insight.citationSegmentIDs.isEmpty {
                        suffix.append("Evidence: " + insight.citationSegmentIDs.map { "[\($0.uuidString)]" }.joined(separator: " "))
                    }
                    sections.append("- \(insight.text)" + (suffix.isEmpty ? "" : " (\(suffix.joined(separator: "; ")))") )
                }
            }
            if !generated.followUpEmail.isEmpty {
                sections.append(contentsOf: ["", "## Follow-up email", "", generated.followUpEmail])
            }
        }

        if !meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(contentsOf: ["", "## My notes", "", meeting.rawNotes])
        }

        sections.append(contentsOf: ["", "## Transcript", ""])
        for segment in meeting.transcript {
            sections.append("- [\(timestamp(segment.startTime))] **\(segment.displaySpeaker):** \(segment.text) {#\(segment.id.uuidString)}")
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
