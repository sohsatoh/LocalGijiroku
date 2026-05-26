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
    /// Per-session override for the LLM summary style. Highest priority in the
    /// resolution chain.
    public var summaryStyle: SummaryStyle?

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        title: String = "Untitled",
        startedAt: Date = .now,
        endedAt: Date? = nil,
        transcript: [TranscriptSegment] = [],
        summary: CumulativeSummary = CumulativeSummary(),
        events: [MeetingEvent] = [],
        summaryStyle: SummaryStyle? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
        self.summary = summary
        self.events = events
        self.summaryStyle = summaryStyle
    }
}
