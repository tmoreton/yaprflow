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

public enum MeetingTranscriptTimestamp {
    public static func string(for interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

/// Removes Mac playback that the microphone hears a second time and keeps the
/// persisted transcript chronological. System audio is the authoritative copy
/// when the same words occur in overlapping `Me` and `Them` segments.
public enum MeetingTranscriptReconciler {
    public static func reconcile(_ segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        var result = segments.sorted(by: isEarlier)
        let systemSegments = result.filter { $0.speaker == .them }

        for systemSegment in systemSegments {
            for index in result.indices where result[index].speaker == .me {
                guard overlaps(result[index], systemSegment) else { continue }
                result[index].text = removingSystemEcho(
                    systemSegment.text,
                    from: result[index].text
                )
            }
        }

        return result
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: isEarlier)
    }

    public static func newestFirst(_ segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        segments.sorted {
            if $0.startTime != $1.startTime { return $0.startTime > $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime > $1.endTime }
            return $0.speaker.rawValue < $1.speaker.rawValue
        }
    }

    private struct WordToken {
        let value: String
        let range: Range<String.Index>
    }

    private struct TokenMatch {
        let microphoneIndex: Int
        let systemIndex: Int
    }

    private static func isEarlier(
        _ lhs: MeetingTranscriptSegment,
        _ rhs: MeetingTranscriptSegment
    ) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.speaker.rawValue < rhs.speaker.rawValue
    }

    private static func overlaps(
        _ lhs: MeetingTranscriptSegment,
        _ rhs: MeetingTranscriptSegment
    ) -> Bool {
        let tolerance: TimeInterval = 2
        return lhs.startTime <= rhs.endTime + tolerance
            && rhs.startTime <= lhs.endTime + tolerance
    }

    private static func removingSystemEcho(_ systemText: String, from microphoneText: String) -> String {
        let microphoneTokens = tokens(in: microphoneText)
        let systemTokens = tokens(in: systemText)
        guard microphoneTokens.count >= 3, systemTokens.count >= 3 else { return microphoneText }

        let matches = fuzzyOrderedMatches(microphoneTokens, systemTokens)
        let groups = matchGroups(matches)
        let echoRanges = groups.compactMap { group -> Range<String.Index>? in
            guard let firstMatch = group.first, let lastMatch = group.last else { return nil }
            let microphoneSpan = lastMatch.microphoneIndex - firstMatch.microphoneIndex + 1
            let matchedCharacters = group.reduce(into: 0) { count, match in
                count += microphoneTokens[match.microphoneIndex].value.count
            }
            let coverage = Double(group.count) / Double(microphoneSpan)
            guard group.count >= 4, matchedCharacters >= 15, coverage >= 0.6 else { return nil }
            return microphoneTokens[firstMatch.microphoneIndex].range.lowerBound
                ..< microphoneTokens[lastMatch.microphoneIndex].range.upperBound
        }
        guard !echoRanges.isEmpty else { return microphoneText }

        var cleaned = microphoneText
        for range in echoRanges.reversed() {
            cleaned.removeSubrange(range)
        }
        let trimming = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let remainder = cleaned
            .split(whereSeparator: \Character.isWhitespace)
            .filter { !$0.trimmingCharacters(in: .punctuationCharacters).isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: trimming)
        return TranscriptSegments.capitalizingFirstLetter(in: remainder)
    }

    /// Finds an ordered token alignment while tolerating the small spelling
    /// changes and omissions produced when two recognizers hear the same audio.
    private static func fuzzyOrderedMatches(
        _ microphoneTokens: [WordToken],
        _ systemTokens: [WordToken]
    ) -> [TokenMatch] {
        var lengths = Array(
            repeating: [Int](repeating: 0, count: systemTokens.count + 1),
            count: microphoneTokens.count + 1
        )
        for microphoneIndex in 1...microphoneTokens.count {
            for systemIndex in 1...systemTokens.count {
                if tokensAreSimilar(
                    microphoneTokens[microphoneIndex - 1].value,
                    systemTokens[systemIndex - 1].value
                ) {
                    lengths[microphoneIndex][systemIndex] = lengths[microphoneIndex - 1][systemIndex - 1] + 1
                } else {
                    lengths[microphoneIndex][systemIndex] = max(
                        lengths[microphoneIndex - 1][systemIndex],
                        lengths[microphoneIndex][systemIndex - 1]
                    )
                }
            }
        }

        var microphoneIndex = microphoneTokens.count
        var systemIndex = systemTokens.count
        var matches: [TokenMatch] = []
        while microphoneIndex > 0, systemIndex > 0 {
            if tokensAreSimilar(
                microphoneTokens[microphoneIndex - 1].value,
                systemTokens[systemIndex - 1].value
            ), lengths[microphoneIndex][systemIndex] == lengths[microphoneIndex - 1][systemIndex - 1] + 1 {
                matches.append(TokenMatch(
                    microphoneIndex: microphoneIndex - 1,
                    systemIndex: systemIndex - 1
                ))
                microphoneIndex -= 1
                systemIndex -= 1
            } else if lengths[microphoneIndex - 1][systemIndex] >= lengths[microphoneIndex][systemIndex - 1] {
                microphoneIndex -= 1
            } else {
                systemIndex -= 1
            }
        }
        return matches.reversed()
    }

    /// Echo words should occupy a dense span in the microphone transcript.
    /// A gap of more than three microphone words starts a separate candidate,
    /// preventing unrelated words elsewhere in the segment from being removed.
    private static func matchGroups(_ matches: [TokenMatch]) -> [[TokenMatch]] {
        matches.reduce(into: [[TokenMatch]]()) { groups, match in
            if let previous = groups.last?.last,
               match.microphoneIndex - previous.microphoneIndex <= 3 {
                groups[groups.count - 1].append(match)
            } else {
                groups.append([match])
            }
        }
    }

    private static func tokensAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return lhs.count >= 3 }
        let minimumLength = min(lhs.count, rhs.count)
        guard minimumLength >= 4 else { return false }
        if lhs.commonPrefix(with: rhs).count >= 4 { return true }
        guard lhs.first == rhs.first else { return false }
        return editDistance(lhs, rhs) <= 2
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + [Int](repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func tokens(in text: String) -> [WordToken] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [WordToken] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let normalized = String(text[range])
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber || $0 == "'" }
            if !normalized.isEmpty {
                result.append(WordToken(value: normalized, range: range))
            }
            return true
        }
        return result
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
    public var suggestedTitle: String?
    public var overview: String
    public var insights: [MeetingInsight]
    public var followUpEmail: String
    public var generatedAt: Date

    public init(
        suggestedTitle: String? = nil,
        overview: String = "",
        insights: [MeetingInsight] = [],
        followUpEmail: String = "",
        generatedAt: Date = Date()
    ) {
        let normalizedTitle = suggestedTitle?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_# "))
        self.suggestedTitle = normalizedTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
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
            "[\(MeetingTranscriptTimestamp.string(for: segment.startTime))] \(segment.displaySpeaker): \(segment.text)"
        }.joined(separator: "\n")
    }

    public var needsGeneratedTitle: Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty || normalized == "new meeting" || normalized == "untitled meeting"
    }

}

public struct MeetingTemplate: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var systemImage: String
    public var instructions: String
    public var includesFollowUpDraft: Bool

    public init(
        id: String,
        name: String,
        systemImage: String,
        instructions: String,
        includesFollowUpDraft: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.instructions = instructions
        self.includesFollowUpDraft = includesFollowUpDraft
    }
}

public enum MeetingTemplateCatalog {
    public static let generalID = "structured-brief"

    /// Meetings and dictations intentionally share one output catalog.
    /// The prompt is resolved when the menu is shown or generation begins so
    /// edits made in Settings take effect without restarting the app.
    public static var builtIns: [MeetingTemplate] {
        LibraryPromptCatalog.itemPresets.map { preset in
            MeetingTemplate(
                id: preset.id,
                name: preset.title,
                systemImage: preset.systemImage,
                instructions: LibraryPromptPreferences.prompt(for: preset.id),
                includesFollowUpDraft: [
                    LibraryPromptCatalog.salesFollowUp.id,
                    LibraryPromptCatalog.followUpEmail.id,
                ].contains(preset.id)
            )
        }
    }

    public static func template(id: String) -> MeetingTemplate {
        let normalizedID: String
        switch id {
        case "project-review":
            normalizedID = LibraryPromptCatalog.actionPlan.id
        case "detailed-notes":
            normalizedID = LibraryPromptCatalog.detailedNotes.id
        case "general":
            normalizedID = generalID
        default:
            normalizedID = id
        }
        return builtIns.first { $0.id == normalizedID } ?? builtIns[0]
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
        title: "General Summary",
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

    public static let oneToOneNotes = LibraryPromptPreset(
        id: "one-to-one",
        title: "1:1 Notes",
        systemImage: "person.line.dotted.person",
        prompt: """
        Organize this source into useful 1:1 notes. Use only what was actually discussed and never invent feedback, intent, commitments, owners, dates, or personal context. Preserve nuance and distinguish direct feedback from suggestions or observations.

        Use these sections, omitting empty sections:
        ## Check-in and context
        Capture meaningful updates, priorities, and changes since the last conversation.
        ## Feedback and coaching
        Separate feedback that was given from topics that were merely explored.
        ## Goals and development
        Record stated goals, growth areas, support requested, and agreed next steps.
        ## Commitments
        Format each item as: - [ ] Action — Owner: name or Not stated — Due: date or Not stated
        ## Topics to revisit
        List unresolved questions, concerns, and items for the next 1:1.
        """
    )

    public static let interviewNotes = LibraryPromptPreset(
        id: "interview",
        title: "Interview Notes",
        systemImage: "person.crop.rectangle",
        prompt: """
        Turn this source into evidence-based interview notes. Use only statements and examples in the source. Never invent qualifications, sentiment, scores, answers, or a hiring recommendation. Keep interviewer commentary distinct from candidate evidence.

        Use these sections, omitting empty sections:
        ## Interview context
        State the role, stage, and interview focus only when provided.
        ## Evidence by topic or question
        Group concrete answers and examples under descriptive headings.
        ## Demonstrated strengths
        Include the supporting example for every strength.
        ## Concerns and missing evidence
        Separate an observed concern from an area that simply was not covered.
        ## Candidate questions
        Preserve questions the candidate asked and any answers given.
        ## Recommended next step
        Include only a recommendation explicitly stated in the source; otherwise write Not stated.
        """
    )

    public static let researchSynthesis = LibraryPromptPreset(
        id: "user-research",
        title: "Research Synthesis",
        systemImage: "quote.bubble",
        prompt: """
        Synthesize this source into trustworthy user-research notes. Use only observed or stated evidence and never invent user needs, frequency, severity, quotes, consensus, or product conclusions. Clearly distinguish evidence from interpretation and proposed opportunities.

        Use these sections, omitting empty sections:
        ## Participant goals and context
        ## Current workflow
        Describe the steps, tools, workarounds, and constraints the participant actually mentioned.
        ## Pain points
        Pair each pain point with its supporting behavior, example, or quotation.
        ## Needs and requests
        Separate explicit requests from inferred opportunities.
        ## Notable evidence
        Preserve short verbatim quotes only when they appear in the source; do not fabricate quotes.
        ## Opportunities and open questions
        Label opportunities as hypotheses and list what still needs validation.
        """
    )

    public static let salesFollowUp = LibraryPromptPreset(
        id: "sales",
        title: "Sales Follow-up",
        systemImage: "chart.line.uptrend.xyaxis",
        prompt: """
        Create a grounded sales-call summary and a concise follow-up draft. Use only facts in the source. Never invent a recipient, email address, stakeholder, need, budget, timeline, objection, decision, promise, or next step.

        Organize the notes as follows, omitting empty sections:
        ## Customer goals and needs
        ## Current situation and impact
        ## Qualification signals
        Capture stated stakeholders, timing, budget, evaluation process, and success criteria only when provided.
        ## Questions and objections
        ## Decisions and next steps
        Format actions as: - [ ] Action — Owner: name or Not stated — Due: date or Not stated
        ## Follow-up email
        Draft a warm, direct email with a specific subject, confirmed context, agreed next steps, and open items. Do not add a recipient or contact detail unless it appears verbatim in the source.
        """
    )

    public static let standupUpdate = LibraryPromptPreset(
        id: "standup",
        title: "Standup Update",
        systemImage: "figure.stand",
        prompt: """
        Turn this source into a concise standup update. Use only stated information and never invent progress, completion status, owners, dates, blockers, or priorities. Keep proposed work separate from committed work.

        Use these sections, omitting empty sections:
        ## Updates by person or workstream
        For each person or workstream, capture completed work, work in progress, and the next stated step.
        ## Blockers
        List active blockers and who or what is needed to unblock them.
        ## Dependencies and handoffs
        ## Decisions
        Include only decisions explicitly made.
        ## Today’s commitments
        Format each item as: - [ ] Action — Owner: name or Not stated — Due: date or Not stated
        ## Parking lot
        Capture topics deferred for a longer discussion.
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

    public static let itemPresets = [
        structuredBrief,
        oneToOneNotes,
        interviewNotes,
        researchSynthesis,
        salesFollowUp,
        standupUpdate,
        actionPlan,
        followUpEmail,
        detailedNotes,
    ]
    public static let allMeetingPresets = [executiveBrief, actionTracker, decisionLog, followUpQueue]
    public static let itemDefaultPrompt = structuredBrief.prompt
    public static let allMeetingsDefaultPrompt = executiveBrief.prompt

    public static func itemPreset(id: String) -> LibraryPromptPreset {
        itemPresets.first { $0.id == id } ?? structuredBrief
    }
}

public enum LibraryPromptPreferences {
    private static let keyPrefix = "yaprflow.output-prompt."

    public static func prompt(
        for presetID: String,
        defaults: UserDefaults = .standard
    ) -> String {
        let preset = LibraryPromptCatalog.itemPreset(id: presetID)
        let stored = defaults.string(forKey: keyPrefix + preset.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return preset.prompt
    }

    public static func setPrompt(
        _ prompt: String,
        for presetID: String,
        defaults: UserDefaults = .standard
    ) {
        let preset = LibraryPromptCatalog.itemPreset(id: presetID)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == preset.prompt {
            defaults.removeObject(forKey: keyPrefix + preset.id)
        } else {
            defaults.set(trimmed, forKey: keyPrefix + preset.id)
        }
    }

    public static func reset(
        presetID: String,
        defaults: UserDefaults = .standard
    ) {
        let preset = LibraryPromptCatalog.itemPreset(id: presetID)
        defaults.removeObject(forKey: keyPrefix + preset.id)
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
        let attendeeList = meeting.attendees.map { attendee in
            let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return email.isEmpty ? attendee.name : "\(attendee.name) <\(email)>"
        }.joined(separator: ", ")
        let followUpRule = template.includesFollowUpDraft
            ? "Draft a follow-up body, but include a recipient or contact detail only when it appears verbatim in the source."
            : "Set followUpEmail to an empty string. This output does not request a follow-up draft."
        return """
        Create trustworthy meeting notes and a specific, natural title of 3 to 8 words using the template guidance below.
        Never invent a fact, owner, date, decision, recipient, email address, phone number, URL, or other contact detail. Do not create example or placeholder contact information.
        Prefer the user's raw notes when they emphasize a topic. Copy contact details only when they appear verbatim in the supplied title, attendees, raw notes, or transcript.
        Every insight must cite one or more exact transcript segment UUIDs.
        \(followUpRule)

        Template: \(template.name)
        Guidance: \(template.instructions)
        Meeting title: \(meeting.title)
        Attendees: \(attendeeList.isEmpty ? "Not provided" : attendeeList)

        <raw-notes>
        \(meeting.rawNotes)
        </raw-notes>

        Return only JSON with this shape:
        {"title":"Specific meeting title","overview":"...","insights":[{"kind":"summary|decision|actionItem|openQuestion|keyDetail","text":"...","owner":null,"dueDate":null,"citationSegmentIDs":["UUID"]}],"followUpEmail":"..."}
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

/// Enforces source grounding for contact details after generation. Prompt rules
/// improve model behavior, but generated output is not trusted on its own.
public enum MeetingGeneratedNotesGrounder {
    public static func grounded(
        _ notes: MeetingGeneratedNotes,
        in meeting: MeetingRecord,
        allowsFollowUpDraft: Bool? = nil
    ) -> MeetingGeneratedNotes {
        let trustedEmails = emailAddresses(in: trustedSource(for: meeting))
        let allowsFollowUp = allowsFollowUpDraft
            ?? MeetingTemplateCatalog.template(id: meeting.templateID).includesFollowUpDraft

        let title = notes.suggestedTitle.flatMap { value -> String? in
            containsUnsupportedEmail(in: value, trustedEmails: trustedEmails) ? nil : value
        }
        let overview = replacingUnsupportedEmails(
            in: notes.overview,
            trustedEmails: trustedEmails
        )
        let insights = notes.insights.compactMap { insight -> MeetingInsight? in
            var groundedInsight = insight
            groundedInsight.text = replacingUnsupportedEmails(
                in: insight.text,
                trustedEmails: trustedEmails
            )
            groundedInsight.owner = insight.owner.flatMap {
                containsUnsupportedEmail(in: $0, trustedEmails: trustedEmails) ? nil : $0
            }
            groundedInsight.dueDate = insight.dueDate.flatMap {
                containsUnsupportedEmail(in: $0, trustedEmails: trustedEmails) ? nil : $0
            }
            return groundedInsight.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : groundedInsight
        }

        let followUpEmail: String
        if allowsFollowUp,
           !containsUnsupportedEmail(in: notes.followUpEmail, trustedEmails: trustedEmails) {
            followUpEmail = notes.followUpEmail
        } else {
            followUpEmail = ""
        }

        return MeetingGeneratedNotes(
            suggestedTitle: title,
            overview: overview,
            insights: insights,
            followUpEmail: followUpEmail,
            generatedAt: notes.generatedAt
        )
    }

    private static func trustedSource(for meeting: MeetingRecord) -> String {
        var values = [meeting.title, meeting.rawNotes]
        values.append(contentsOf: meeting.attendees.flatMap { attendee in
            [attendee.name, attendee.email ?? ""]
        })
        values.append(contentsOf: meeting.transcript.flatMap { segment in
            [segment.displaySpeaker, segment.text]
        })
        return values.joined(separator: "\n")
    }

    private static func containsUnsupportedEmail(
        in text: String,
        trustedEmails: Set<String>
    ) -> Bool {
        !emailAddresses(in: text).isSubset(of: trustedEmails)
    }

    private static func replacingUnsupportedEmails(
        in text: String,
        trustedEmails: Set<String>
    ) -> String {
        guard let expression = emailExpression() else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range).reversed()
        var result = text
        for match in matches {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let email = result[swiftRange].lowercased()
            guard !trustedEmails.contains(email) else { continue }
            result.replaceSubrange(swiftRange, with: "contact not provided")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func emailAddresses(in text: String) -> Set<String> {
        guard let expression = emailExpression() else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { text[$0].lowercased() }
        })
    }

    private static func emailExpression() -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        )
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

        let title: String?
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
            suggestedTitle: payload.title,
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
        let suggestedTitle = stringValue(in: values, keys: [
            "title", "meetingtitle", "suggestedtitle",
        ])

        let notes = MeetingGeneratedNotes(
            suggestedTitle: suggestedTitle,
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
            sections.append("- [\(MeetingTranscriptTimestamp.string(for: segment.startTime))] **\(segment.displaySpeaker):** \(segment.text) {#\(segment.id.uuidString)}")
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
