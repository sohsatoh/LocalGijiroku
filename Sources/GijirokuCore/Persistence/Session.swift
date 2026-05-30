import Foundation

public struct Session: Codable, Sendable, Identifiable {
    public let id: UUID
    public var projectId: UUID?
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var transcript: [TranscriptSegment]
    public var summary: CumulativeSummary
    public var events: [MeetingEvent]
    /// Section headings the live recording produced, in chronological order.
    /// Empty for sessions saved before the heading detector existed; the
    /// custom decoder defaults missing entries to `[]` so they keep loading.
    public var headings: [TranscriptHeading]
    /// Per-session override for the LLM summary style. Highest priority in the
    /// resolution chain.
    public var summaryStyle: SummaryStyle?
    /// True when the user has manually set the title; prevents automatic
    /// title generation from overwriting it.
    public var isTitleManuallyEdited: Bool

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        title: String = "Untitled",
        startedAt: Date = .now,
        endedAt: Date? = nil,
        transcript: [TranscriptSegment] = [],
        summary: CumulativeSummary = CumulativeSummary(),
        events: [MeetingEvent] = [],
        headings: [TranscriptHeading] = [],
        summaryStyle: SummaryStyle? = nil,
        isTitleManuallyEdited: Bool = false
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
        self.summary = summary
        self.events = events
        self.headings = headings
        self.summaryStyle = summaryStyle
        self.isTitleManuallyEdited = isTitleManuallyEdited
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, startedAt, endedAt
        case transcript, summary, events, headings, summaryStyle
        case isTitleManuallyEdited
    }

    /// Custom decoder so sessions saved before `headings` / `isTitleManuallyEdited`
    /// existed still load — missing fields default to safe values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectId = try? c.decode(UUID.self, forKey: .projectId)
        self.title = try c.decode(String.self, forKey: .title)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.endedAt = try? c.decode(Date.self, forKey: .endedAt)
        self.transcript = (try? c.decode([TranscriptSegment].self, forKey: .transcript)) ?? []
        self.summary = (try? c.decode(CumulativeSummary.self, forKey: .summary)) ?? CumulativeSummary()
        self.events = (try? c.decode([MeetingEvent].self, forKey: .events)) ?? []
        self.headings = (try? c.decode([TranscriptHeading].self, forKey: .headings)) ?? []
        self.summaryStyle = try? c.decode(SummaryStyle.self, forKey: .summaryStyle)
        self.isTitleManuallyEdited = (try? c.decode(Bool.self, forKey: .isTitleManuallyEdited)) ?? false
    }
}
