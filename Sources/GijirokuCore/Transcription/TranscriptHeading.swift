import Foundation

/// A section heading inserted into the transcript while the meeting is
/// running. The heading text reflects what the assistant believes is
/// currently being discussed; `startTime` anchors the heading to the
/// point in the transcript where the new topic begins, so the UI can
/// interleave headings and segments in chronological order without
/// needing a positional index.
///
/// Persisted alongside the transcript on the `Session` so that reopening
/// a recording later still shows the topic structure that emerged
/// live — without having to re-run the heading model.
public struct TranscriptHeading: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    /// Wall-clock time the new topic is considered to have started.
    /// Anchored to the first segment of the window that triggered the
    /// heading change, so the UI can place the heading immediately above
    /// the speaker turn that introduced the new thread.
    public let startTime: Date
    /// When the assistant produced this heading. Used for debug / audit;
    /// the UI never displays it.
    public let detectedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: Date,
        detectedAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.detectedAt = detectedAt
    }
}
