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

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        speaker: String? = nil,
        text: String,
        startTime: Date,
        endTime: Date,
        isFinal: Bool,
        confidence: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment>
}
