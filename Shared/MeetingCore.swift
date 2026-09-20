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

public struct LibraryPromptPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let prompt: String

    public init(id: String, title: String, systemImage: String, prompt: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.prompt = prompt
    }
}

public enum LibraryPromptCatalog {
    public static let structuredBrief = LibraryPromptPreset(
        id: "structured-brief",
        title: "Structured Brief",
        systemImage: "doc.text",
        prompt: """
        Turn this source into a concise, trustworthy brief. Use only information in the source. Do not invent or infer missing facts, owners, dates, decisions, or intent. Preserve important names, numbers, dates, and commitments, and distinguish confirmed decisions from ideas or proposals.

        Use these sections, omitting any section with no supporting information:
        ## Overview
        Summarize the purpose and outcome in 2–4 sentences.

        ## Key points
        Group related points and remove repetition.

        ## Decisions
        List only decisions that were explicitly made.

        ## Action items
        Format each item as: - [ ] Action — Owner: name or Not stated — Due: date or Not stated

        ## Open questions
        Capture unresolved questions, disagreements, and information still needed.

        ## Important details
        Retain exact names, figures, dates, links, constraints, and dependencies that matter later.
        """
    )

    public static let actionPlan = LibraryPromptPreset(
        id: "action-plan",
        title: "Action Plan",
        systemImage: "checklist",
        prompt: """
        Convert this source into an execution-ready action plan. Use only stated information and never invent an owner, deadline, status, dependency, or priority. Merge duplicate commitments while preserving meaningful differences.

        Use these sections, omitting empty sections:
        ## Intended outcome
        State the result the work is meant to achieve.

        ## Next actions
        Format each item as: - [ ] Action — Owner: name or Not stated — Due: date or Not stated — Status: stated status or Not stated
        Order items by dependency, then urgency when the source makes either clear.

        ## Dependencies and handoffs
        Identify what must happen first and who is waiting on whom.

        ## Risks and blockers
        Separate confirmed blockers from possible risks.

        ## Follow-ups needed
        List missing owners, dates, approvals, or answers that must be clarified.
        """
    )

    public static let followUpEmail = LibraryPromptPreset(
        id: "follow-up-email",
        title: "Follow-up Email",
        systemImage: "envelope",
        prompt: """
        Draft a concise, professional follow-up email from this source. Use only facts in the source and do not invent recipients, decisions, owners, dates, or commitments. Keep the tone warm, direct, and easy to scan.

        Output:
        Subject: a specific subject line

        A brief opening that states the shared context or outcome.

        Decisions
        - Only explicitly confirmed decisions.

        Next steps
        - [ ] Action — Owner: name or Not stated — Due: date or Not stated

        Open items
        - Questions, approvals, or blockers that still need resolution.

        End with a short confirmation request or next checkpoint. Omit any section that the source does not support, and do not include commentary outside the email.
        """
    )

    public static let detailedNotes = LibraryPromptPreset(
        id: "detailed-notes",
        title: "Detailed Notes",
        systemImage: "list.bullet.rectangle",
        prompt: """
        Organize this source into detailed reference notes without losing nuance. Use only the source and do not invent facts or silently turn suggestions into decisions. Consolidate repetition, preserve dissent and uncertainty, and retain exact names, dates, numbers, constraints, examples, and terminology.

        Use these sections, omitting empty sections:
        ## Context and goals
        ## Discussion by topic
        Group the material under descriptive topic headings and capture the reasoning, alternatives, and tradeoffs discussed.
        ## Decisions
        ## Action items
        Include owner and due date when stated; otherwise write Not stated.
        ## Open questions and risks
        ## Key facts and references

        Prefer clear bullets, but use short paragraphs where the reasoning would be lost in a bullet.
        """
    )

    public static let executiveBrief = LibraryPromptPreset(
        id: "executive-brief",
        title: "Executive Brief",
        systemImage: "sparkles.rectangle.stack",
        prompt: """
        Build an executive brief from the relevant saved meetings. Use only supported evidence. Never invent a fact, owner, deadline, decision, or trend, and do not present a proposal as an agreement. Combine duplicates and call out meaningful conflicts between meetings.

        Use these sections, omitting empty sections:
        ## Executive overview
        Summarize the most consequential outcomes and changes in 3–5 sentences.

        ## Decisions
        List confirmed decisions and name the source meeting for each.

        ## Commitments and next steps
        Format each item as: - [ ] Action — Owner: name or Not stated — Due: date or Not stated — Meeting: title

        ## Risks and blockers
        Distinguish active blockers from potential risks.

        ## Open questions
        Capture unresolved issues and the next clarification needed.

        Cite every substantive bullet with the exact bracketed meeting or segment reference supplied in the source.
        """
    )

    public static let actionTracker = LibraryPromptPreset(
        id: "action-tracker",
        title: "Action Tracker",
        systemImage: "checkmark.circle",
        prompt: """
        Find explicit commitments, assigned work, deadlines, handoffs, and follow-ups across the relevant saved meetings. Use only supported evidence, merge true duplicates, and never invent an owner, date, priority, or completion status.

        Organize the result as:
        ## Assigned actions
        - [ ] Action — Owner: name — Due: date or Not stated — Status: stated status or Not stated — Meeting: title

        ## Unassigned actions
        - [ ] Action — Owner: Not stated — Due: date or Not stated — Meeting: title

        ## Blocked or dependent work
        Explain the blocker or dependency and the action it affects.

        ## Follow-ups to clarify
        List missing owners, dates, approvals, and conflicting commitments.

        Cite every item with the exact bracketed meeting or segment reference supplied in the source. If an action is only suggested, label it Proposed rather than Assigned.
        """
    )

    public static let decisionLog = LibraryPromptPreset(
        id: "decision-log",
        title: "Decision Log",
        systemImage: "signpost.right.and.left",
        prompt: """
        Create a decision log across the relevant saved meetings. Include only decisions that were explicitly confirmed; keep recommendations, options, and unresolved debates separate. Never invent rationale, owners, dates, or consequences.

        For each confirmed decision, provide:
        ## Decision: short outcome
        - Meeting: title
        - Decision: what was agreed
        - Rationale: stated reasoning, or Not stated
        - Owner: name, or Not stated
        - Effective date or deadline: date, or Not stated
        - Implications: only consequences explicitly discussed
        - Remaining uncertainty: any unresolved part

        Then add:
        ## Pending decisions
        List decisions still awaiting input, approval, or a tie-breaker.

        Cite every entry with the exact bracketed meeting or segment reference supplied in the source. Note conflicts when later meetings revise an earlier decision.
        """
    )

    public static let followUpQueue = LibraryPromptPreset(
        id: "follow-up-queue",
        title: "Follow-up Queue",
        systemImage: "paperplane",
        prompt: """
        Identify the highest-value follow-ups across the relevant saved meetings and turn them into a concise outreach queue. Use only supported evidence. Never invent a recipient, promise, owner, date, or decision.

        For each follow-up, provide:
        ## Follow-up: short purpose
        - Source meeting: title
        - Recipient: stated person or Not stated
        - Goal: the answer, confirmation, approval, or action needed
        - Owner: stated person or Not stated
        - Due: stated date or Not stated
        - Context: one sentence explaining why it matters

        Draft a short ready-to-send message with a specific subject line, a direct request, and the relevant confirmed context. Keep each draft under 120 words. Limit the queue to the five most consequential follow-ups and cite each one with the exact bracketed meeting or segment reference supplied in the source.
        """
    )

    public static let itemPresets = [structuredBrief, actionPlan, followUpEmail, detailedNotes]
    public static let allMeetingPresets = [executiveBrief, actionTracker, decisionLog, followUpQueue]
    public static let itemDefaultPrompt = structuredBrief.prompt
    public static let allMeetingsDefaultPrompt = executiveBrief.prompt
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
    private enum ParseError: Error {
        case emptyResponse
    }

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
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyResponse }

        let json = extractedJSONObject(from: trimmed)
        for candidate in jsonCandidates(from: json) {
            if let payload = try? JSONDecoder().decode(Payload.self, from: Data(candidate.utf8)) {
                return notes(from: payload, validSegmentIDs: validSegmentIDs)
            }
            if let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
               let dictionary = notesDictionary(from: object),
               let notes = flexibleNotes(from: dictionary, validSegmentIDs: validSegmentIDs) {
                return notes
            }
        }

        // Some local and smaller models honor the requested sections but return
        // Markdown instead of JSON. The content is still useful, so retain it as
        // readable notes rather than discarding a successfully saved transcript.
        return plainTextNotes(from: trimmed, validSegmentIDs: validSegmentIDs)
    }

    private static func extractedJSONObject(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first <= last else { return trimmed }
        return String(trimmed[first...last])
    }

    private static func jsonCandidates(from json: String) -> [String] {
        let normalizedQuotes = json
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        let withoutTrailingCommas = normalizedQuotes.replacingOccurrences(
            of: #",\s*([}\]])"#,
            with: "$1",
            options: .regularExpression
        )
        return withoutTrailingCommas == json ? [json] : [json, withoutTrailingCommas]
    }

    private static func notes(from payload: Payload, validSegmentIDs: Set<UUID>) -> MeetingGeneratedNotes {
        MeetingGeneratedNotes(
            overview: payload.overview,
            insights: payload.insights.map { item in
                MeetingInsight(
                    kind: item.kind,
                    text: item.text,
                    owner: item.owner,
                    dueDate: item.dueDate,
                    citationSegmentIDs: item.citationSegmentIDs.filter(validSegmentIDs.contains)
                )
            },
            followUpEmail: payload.followUpEmail
        )
    }

    private static func notesDictionary(from object: Any) -> [String: Any]? {
        if let array = object as? [Any], array.count == 1 {
            return notesDictionary(from: array[0])
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        let normalized = normalizedDictionary(dictionary)
        for key in ["meetingnotes", "generatednotes", "notes", "result"] {
            if let nested = normalized[key] as? [String: Any] {
                return nested
            }
        }
        return dictionary
    }

    private static func flexibleNotes(
        from dictionary: [String: Any],
        validSegmentIDs: Set<UUID>
    ) -> MeetingGeneratedNotes? {
        let values = normalizedDictionary(dictionary)
        var insights: [MeetingInsight] = []

        if let items = values["insights"] as? [Any] {
            insights.append(contentsOf: items.compactMap {
                insight(from: $0, defaultKind: .keyDetail, validSegmentIDs: validSegmentIDs)
            })
        }

        let groupedKinds: [(keys: [String], kind: MeetingInsightKind)] = [
            (["keypoints", "highlights", "summarypoints"], .summary),
            (["decisions"], .decision),
            (["actionitems", "actions", "nextsteps", "todos", "tasks"], .actionItem),
            (["openquestions", "questions", "unresolvedquestions"], .openQuestion),
            (["keydetails", "details", "facts"], .keyDetail),
        ]
        for group in groupedKinds {
            for key in group.keys {
                guard let value = values[key] else { continue }
                let items = value as? [Any] ?? [value]
                insights.append(contentsOf: items.compactMap {
                    insight(from: $0, defaultKind: group.kind, validSegmentIDs: validSegmentIDs)
                })
                break
            }
        }

        var overview = stringValue(in: values, keys: [
            "overview", "meetingsummary", "executivesummary", "summary",
        ]) ?? ""
        if overview.isEmpty {
            overview = insights
                .filter { $0.kind == .summary }
                .prefix(3)
                .map(\.text)
                .joined(separator: " ")
        }
        let followUpEmail = stringValue(in: values, keys: [
            "followupemail", "followup", "emaildraft", "email",
        ]) ?? ""

        let notes = MeetingGeneratedNotes(
            overview: overview,
            insights: deduplicated(insights),
            followUpEmail: followUpEmail
        )
        guard !notes.overview.isEmpty || !notes.insights.isEmpty || !notes.followUpEmail.isEmpty else {
            return nil
        }
        return notes
    }

    private static func insight(
        from value: Any,
        defaultKind: MeetingInsightKind,
        validSegmentIDs: Set<UUID>
    ) -> MeetingInsight? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return MeetingInsight(
                kind: defaultKind,
                text: trimmed,
                citationSegmentIDs: citationIDs(in: trimmed, validSegmentIDs: validSegmentIDs)
            )
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        let values = normalizedDictionary(dictionary)
        guard let text = stringValue(in: values, keys: [
            "text", "content", "description", "summary", "action", "item", "decision", "question", "detail",
        ]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let kind = stringValue(in: values, keys: ["kind", "type", "category"])
            .flatMap(insightKind(from:)) ?? defaultKind
        let citationsValue = firstValue(in: values, keys: [
            "citationsegmentids", "segmentids", "citations", "evidence",
        ])
        return MeetingInsight(
            kind: kind,
            text: text,
            owner: stringValue(in: values, keys: ["owner", "assignee"]),
            dueDate: stringValue(in: values, keys: ["duedate", "deadline", "due"]),
            citationSegmentIDs: citationIDs(
                in: citationsValue ?? text,
                validSegmentIDs: validSegmentIDs
            )
        )
    }

    private static func insightKind(from value: String) -> MeetingInsightKind? {
        switch normalizedKey(value) {
        case "summary", "keypoint", "keypoints", "point", "highlight", "highlights": .summary
        case "decision", "decisions", "decided": .decision
        case "actionitem", "actionitems", "action", "actions", "nextstep", "nextsteps", "todo", "todos", "task", "tasks": .actionItem
        case "openquestion", "openquestions", "question", "questions", "unresolved": .openQuestion
        case "keydetail", "keydetails", "detail", "details", "fact", "facts": .keyDetail
        default: nil
        }
    }

    private static func citationIDs(in value: Any, validSegmentIDs: Set<UUID>) -> [UUID] {
        let strings: [String]
        if let values = value as? [Any] {
            strings = values.compactMap {
                if let string = $0 as? String { return string }
                return ($0 as? UUID)?.uuidString
            }
        } else if let string = value as? String {
            strings = [string]
        } else if let uuid = value as? UUID {
            strings = [uuid.uuidString]
        } else {
            return []
        }

        var result: [UUID] = []
        for string in strings {
            let components = string.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            for component in components {
                guard let id = UUID(uuidString: component),
                      validSegmentIDs.contains(id),
                      !result.contains(id) else { continue }
                result.append(id)
            }
        }
        return result
    }

    private static func plainTextNotes(
        from response: String,
        validSegmentIDs: Set<UUID>
    ) -> MeetingGeneratedNotes {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```markdown", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return MeetingGeneratedNotes()
        }

        var overviewLines: [String] = []
        var followUpLines: [String] = []
        var insights: [MeetingInsight] = []
        var activeKind: MeetingInsightKind?
        var isFollowUp = false

        for rawLine in cleaned.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let heading = normalizedKey(
                line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
            )
            if heading == "summary" || heading == "overview" || heading == "executivesummary" {
                activeKind = nil
                isFollowUp = false
                continue
            }
            if let kind = insightKind(from: heading) {
                activeKind = kind
                isFollowUp = false
                continue
            }
            if heading == "followupemail" || heading == "followup" || heading == "emaildraft" {
                activeKind = nil
                isFollowUp = true
                continue
            }

            let content = strippedListMarker(from: line)
            if isFollowUp {
                followUpLines.append(content)
            } else if let activeKind {
                insights.append(MeetingInsight(
                    kind: activeKind,
                    text: content,
                    citationSegmentIDs: citationIDs(in: content, validSegmentIDs: validSegmentIDs)
                ))
            } else {
                overviewLines.append(content)
            }
        }

        let overview = overviewLines.joined(separator: "\n")
        return MeetingGeneratedNotes(
            overview: overview.isEmpty && insights.isEmpty ? cleaned : overview,
            insights: deduplicated(insights),
            followUpEmail: followUpLines.joined(separator: "\n")
        )
    }

    private static func normalizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.map { (normalizedKey($0.key), $0.value) })
    }

    private static func strippedListMarker(from line: String) -> String {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return line.replacingOccurrences(
            of: #"^\d+[.)]\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func firstValue(in values: [String: Any], keys: [String]) -> Any? {
        keys.lazy.compactMap { values[normalizedKey($0)] }.first
    }

    private static func stringValue(in values: [String: Any], keys: [String]) -> String? {
        guard let value = firstValue(in: values, keys: keys), !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func deduplicated(_ insights: [MeetingInsight]) -> [MeetingInsight] {
        var seen: Set<String> = []
        return insights.filter { insight in
            let key = "\(insight.kind.rawValue):\(insight.text.lowercased())"
            return seen.insert(key).inserted
        }
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
