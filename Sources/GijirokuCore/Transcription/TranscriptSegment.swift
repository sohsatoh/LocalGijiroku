import Foundation

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let source: AudioSource
    public let speaker: String?
    public let text: String
    public let startTime: Date
    public let endTime: Date
    public let isFinal: Bool
    public let confidence: Double?
    /// True once a later inference pass has had enough audio context to
    /// confirm this segment's text won't be rewritten. Drives both the UI
    /// (unconfirmed text renders dimmed) and the downstream pipeline
    /// (autosave / summary / regenerate only see confirmed segments — they
    /// produce unstable output otherwise). Defaults to true so legacy
    /// callers and saved sessions read clean.
    public let isConfirmed: Bool

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        speaker: String? = nil,
        text: String,
        startTime: Date,
        endTime: Date,
        isFinal: Bool,
        confidence: Double? = nil,
        isConfirmed: Bool = true
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
        self.confidence = confidence
        self.isConfirmed = isConfirmed
    }

    /// Codable decoder that tolerates session files saved before
    /// `isConfirmed` existed — missing key reads as `true` so old
    /// sessions show as fully-confirmed transcripts.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.source = try c.decode(AudioSource.self, forKey: .source)
        self.speaker = try? c.decode(String.self, forKey: .speaker)
        self.text = try c.decode(String.self, forKey: .text)
        self.startTime = try c.decode(Date.self, forKey: .startTime)
        self.endTime = try c.decode(Date.self, forKey: .endTime)
        self.isFinal = try c.decode(Bool.self, forKey: .isFinal)
        self.confidence = try? c.decode(Double.self, forKey: .confidence)
        self.isConfirmed = (try? c.decode(Bool.self, forKey: .isConfirmed)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, speaker, text, startTime, endTime, isFinal, confidence, isConfirmed
    }
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment>
}
