import Foundation

/// In-place deduplicator for streaming `TranscriptSegment` values.
///
/// The Whisper streaming engine re-transcribes the same rolling window every
/// few seconds, so the raw stream tends to repeat the same utterance multiple
/// times with minor variations (extra/missing punctuation, slightly longer
/// tail as more audio accumulates). This type folds those repeats into a
/// single segment in `transcript`, keeping the longest text and the widest
/// time range observed.
///
/// Returned `MergeOutcome` tells the caller whether the call mutated an
/// existing item (so it can update the corresponding entry in any "pending
/// for summary" buffer) or appended a new one.
public struct TranscriptDeduper {
    public enum MergeOutcome: Equatable {
        case appended
        case replaced(previousID: UUID)
        case ignored
    }

    public struct Config: Sendable {
        public var lookbackWindow: Int
        public var similarityThreshold: Float
        /// Only segments whose start times are within this many seconds of an
        /// existing entry are eligible for merging. Prevents accidental merges
        /// like "今日" and a much later "今日は雨だ".
        public var maxStartTimeDelta: TimeInterval

        public init(
            lookbackWindow: Int = 8,
            similarityThreshold: Float = 0.7,
            maxStartTimeDelta: TimeInterval = 12
        ) {
            self.lookbackWindow = lookbackWindow
            self.similarityThreshold = similarityThreshold
            self.maxStartTimeDelta = maxStartTimeDelta
        }
    }

    public let config: Config

    public init(config: Config = .init()) {
        self.config = config
    }

    /// Merges `incoming` into `transcript`, in place. Returns the outcome so
    /// callers can keep secondary buffers (pending-for-summary etc.) in sync.
    public func merge(_ incoming: TranscriptSegment, into transcript: inout [TranscriptSegment]) -> MergeOutcome {
        let recent = transcript.suffix(config.lookbackWindow)
        for existing in recent.reversed() {
            guard existing.source == incoming.source else { continue }
            let timeDelta = abs(existing.startTime.timeIntervalSince(incoming.startTime))
            guard timeDelta <= config.maxStartTimeDelta else { continue }
            let sim = Self.similarity(existing.text, incoming.text)
            guard sim >= config.similarityThreshold else { continue }
            guard let idx = transcript.lastIndex(where: { $0.id == existing.id }) else { continue }
            let preferLonger = incoming.text.count >= existing.text.count
            let mergedText = preferLonger ? incoming.text : existing.text
            // If nothing actually changes, treat as a no-op.
            if mergedText == existing.text,
               incoming.startTime >= existing.startTime,
               incoming.endTime <= existing.endTime,
               incoming.isFinal == existing.isFinal {
                return .ignored
            }
            transcript[idx] = TranscriptSegment(
                id: existing.id,
                source: existing.source,
                speaker: incoming.speaker ?? existing.speaker,
                text: mergedText,
                startTime: min(existing.startTime, incoming.startTime),
                endTime: max(existing.endTime, incoming.endTime),
                isFinal: incoming.isFinal || existing.isFinal,
                confidence: incoming.confidence ?? existing.confidence
            )
            return .replaced(previousID: existing.id)
        }
        transcript.append(incoming)
        return .appended
    }

    /// Token-set Jaccard similarity tuned for short Whisper segments.
    /// Treats CJK character n-grams (n=2) and ASCII whitespace-split tokens
    /// uniformly, which handles both English and Japanese reasonably well.
    static func similarity(_ a: String, _ b: String) -> Float {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0 }
        // Containment is a strong signal that one is the rolling-window
        // extension of the other; treat as fully similar regardless of length
        // ratio. The caller still gates merging by time proximity.
        if a.contains(b) || b.contains(a) {
            return 1.0
        }
        let tokensA = tokens(a)
        let tokensB = tokens(b)
        if tokensA.isEmpty || tokensB.isEmpty { return 0 }
        let inter = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        guard union > 0 else { return 0 }
        return Float(inter) / Float(union)
    }

    private static func tokens(_ s: String) -> Set<String> {
        var set = Set<String>()
        // ASCII whitespace tokens
        for piece in s.split(whereSeparator: { $0.isWhitespace }) {
            if piece.count > 0 { set.insert(String(piece)) }
        }
        // CJK character bigrams to give Japanese / Chinese a chance to match.
        let chars = Array(s)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                set.insert(String(chars[i...(i + 1)]))
            }
        }
        return set
    }
}
