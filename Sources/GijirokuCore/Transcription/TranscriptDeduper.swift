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
        /// When true, a microphone segment whose text matches a recent system
        /// audio segment (within `crossSourceTimeDelta`) is treated as speaker
        /// bleed and suppressed. This is what we use instead of Apple's
        /// VoiceProcessingIO — the audio path stays untouched (no ducking, no
        /// AGC artifacts) and the duplicate transcription is dropped at the
        /// transcript layer.
        public var crossSourceBleedSuppression: Bool
        /// Time window for the cross-source match. Bleed lag (acoustic +
        /// buffering) is well under 1s, but rolling-window Whisper output can
        /// shift segment timestamps by a few seconds, so we accept a wider
        /// window than maxStartTimeDelta is intended for.
        public var crossSourceTimeDelta: TimeInterval
        /// Bigram-overlap ratio at which a recent entry is treated as
        /// "subsumed" by the just-merged segment and swept away. Different
        /// from `similarityThreshold` (Jaccard, symmetric) because
        /// subsumption is directional: a short "今回高橋総理と面会されまして"
        /// can be > 70 % subsumed by a long "今回、高市総理と面会されまして、
        /// どのような話が…" even though their symmetric Jaccard is well
        /// below 0.7 (the long one drags the union size up).
        public var subsumptionThreshold: Float

        public init(
            lookbackWindow: Int = 8,
            similarityThreshold: Float = 0.7,
            maxStartTimeDelta: TimeInterval = 12,
            crossSourceBleedSuppression: Bool = true,
            crossSourceTimeDelta: TimeInterval = 6,
            subsumptionThreshold: Float = 0.7
        ) {
            self.lookbackWindow = lookbackWindow
            self.similarityThreshold = similarityThreshold
            self.maxStartTimeDelta = maxStartTimeDelta
            self.crossSourceBleedSuppression = crossSourceBleedSuppression
            self.crossSourceTimeDelta = crossSourceTimeDelta
            self.subsumptionThreshold = subsumptionThreshold
        }
    }

    public let config: Config

    public init(config: Config = .init()) {
        self.config = config
    }

    /// Merges `incoming` into `transcript`, in place. Returns the outcome so
    /// callers can keep secondary buffers (pending-for-summary etc.) in sync.
    public func merge(_ incoming: TranscriptSegment, into transcript: inout [TranscriptSegment]) -> MergeOutcome {
        if config.crossSourceBleedSuppression,
           let crossOutcome = mergeAcrossSources(incoming, into: &transcript) {
            return crossOutcome
        }
        // Find ALL eligible matches in the lookback window, not just the
        // first. Two cycles of WhisperKit on the same rolling audio often
        // split the same utterance differently — cycle N might emit
        // ["今日は晴れ。", "明日は雨。"] and cycle N+1 emits a single
        // combined "今日は晴れ。明日は雨。". With early-break-on-first-
        // match, the combined incoming would replace one slot but leave
        // the other as a duplicate fragment. Sweeping all matches lets us
        // collapse subsumed entries in the same pass.
        let lookbackStart = max(0, transcript.count - config.lookbackWindow)
        var matchingIndices: [Int] = []
        for i in lookbackStart..<transcript.count {
            let existing = transcript[i]
            guard existing.source == incoming.source else { continue }
            let timeDelta = abs(existing.startTime.timeIntervalSince(incoming.startTime))
            guard timeDelta <= config.maxStartTimeDelta else { continue }
            let sim = Self.similarity(existing.text, incoming.text)
            guard sim >= config.similarityThreshold else { continue }
            matchingIndices.append(i)
        }

        guard let primaryIdx = matchingIndices.last else {
            transcript.append(incoming)
            return .appended
        }
        let primary = transcript[primaryIdx]

        // Confirmation policy: once a segment is confirmed, its text is
        // immutable. An unconfirmed re-emission for the same region is
        // just stale — the rolling-window transcriber will keep emitting
        // it for a few more cycles until it slides out of the buffer.
        // Don't let it overwrite the confirmed wording.
        let mergedText: String
        if primary.isConfirmed && !incoming.isConfirmed {
            mergedText = primary.text
        } else {
            let preferLonger = incoming.text.count >= primary.text.count
            mergedText = preferLonger ? incoming.text : primary.text
        }
        let mergedConfirmed = primary.isConfirmed || incoming.isConfirmed

        // If nothing actually changes AND there are no subsumed siblings
        // to sweep, it's a true no-op.
        let noChange = mergedText == primary.text &&
            incoming.startTime >= primary.startTime &&
            incoming.endTime <= primary.endTime &&
            incoming.isFinal == primary.isFinal &&
            mergedConfirmed == primary.isConfirmed
        if noChange, matchingIndices.count == 1 {
            return .ignored
        }

        let mergedSegment = TranscriptSegment(
            id: primary.id,
            source: primary.source,
            speaker: incoming.speaker ?? primary.speaker,
            text: mergedText,
            startTime: min(primary.startTime, incoming.startTime),
            endTime: max(primary.endTime, incoming.endTime),
            isFinal: incoming.isFinal || primary.isFinal,
            confidence: incoming.confidence ?? primary.confidence,
            isConfirmed: mergedConfirmed
        )
        transcript[primaryIdx] = mergedSegment

        // Sweep any OTHER recent entries that are subsumed by the merged
        // result. Two complementary checks:
        //   1. Strict substring containment — the obvious case.
        //   2. Directional bigram overlap ratio ≥ subsumptionThreshold —
        //      catches the case where Whisper's wording drifts slightly
        //      between cycles ("高橋総理" → "高市総理", missing 、, etc.),
        //      so strict containment fails but the older fragment is
        //      still effectively a less-accurate version of the same
        //      utterance the merged segment now covers.
        // The check runs against ALL recent entries (same source +
        // time-proximate), not just the ones that already passed the
        // primary similarity threshold — that primary threshold is
        // symmetric Jaccard, which under-counts when the merged is much
        // longer than the existing fragment.
        let mergedBigrams = Self.charBigrams(of: mergedText)
        for i in stride(from: transcript.count - 1, through: lookbackStart, by: -1) where i != primaryIdx {
            let other = transcript[i]
            guard other.source == mergedSegment.source else { continue }
            let timeDelta = abs(other.startTime.timeIntervalSince(mergedSegment.startTime))
            guard timeDelta <= config.maxStartTimeDelta else { continue }
            // Don't sweep confirmed entries with an unconfirmed merge —
            // shouldn't happen in the current model (unconfirmed never
            // enters transcript) but the guard is cheap insurance.
            if other.isConfirmed && !mergedSegment.isConfirmed { continue }
            if Self.isSubsumed(otherText: other.text, mergedText: mergedText, mergedBigrams: mergedBigrams, threshold: config.subsumptionThreshold) {
                transcript.remove(at: i)
            }
        }

        return .replaced(previousID: primary.id)
    }

    /// Directional subsumption test: "is `otherText` mostly inside the
    /// merged result, even allowing for small wording drift?". True when
    /// either the merged text strictly contains the other, or when ≥
    /// `threshold` of the other's character bigrams appear in the
    /// merged text. Uses CHAR bigrams (not the symmetric-similarity
    /// `tokens`) so that whole-string tokens — which inflate the denom
    /// for any space-free CJK text — don't pull the ratio under the
    /// threshold for what is plainly a refinement of the same utterance.
    static func isSubsumed(
        otherText: String,
        mergedText: String,
        mergedBigrams: Set<String>,
        threshold: Float
    ) -> Bool {
        if mergedText.contains(otherText) { return true }
        let otherBigrams = Self.charBigrams(of: otherText)
        guard !otherBigrams.isEmpty else { return false }
        let inter = otherBigrams.intersection(mergedBigrams).count
        return Float(inter) / Float(otherBigrams.count) >= threshold
    }

    /// Character bigram signature — used by the subsumption sweep. Kept
    /// separate from `tokens` so the symmetric similarity check can
    /// continue to mix whitespace-split words + char bigrams for its
    /// purpose (matching short utterances cross-cycle).
    static func charBigrams(of s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var set: Set<String> = []
        set.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            set.insert(String(chars[i...(i + 1)]))
        }
        return set
    }

    /// Cross-source bleed handler: if `incoming` (mic) has similar text to a
    /// recent system segment, treat it as speaker bleed and drop it. If the
    /// inverse arrives — system audio matching a mic segment we already kept —
    /// upgrade the existing entry to source=.system so summaries get the
    /// cleaner version. Returns nil to fall through to the same-source path.
    private func mergeAcrossSources(_ incoming: TranscriptSegment, into transcript: inout [TranscriptSegment]) -> MergeOutcome? {
        let recent = transcript.suffix(config.lookbackWindow)
        for existing in recent.reversed() {
            guard existing.source != incoming.source else { continue }
            let timeDelta = abs(existing.startTime.timeIntervalSince(incoming.startTime))
            guard timeDelta <= config.crossSourceTimeDelta else { continue }
            let sim = Self.similarity(existing.text, incoming.text)
            guard sim >= config.similarityThreshold else { continue }
            if incoming.source == .microphone, existing.source == .system {
                // System already has the clean version — drop the mic bleed.
                return .ignored
            }
            if incoming.source == .system, existing.source == .microphone {
                // The mic captured the bleed first; replace it with the system
                // version. Preserve the original UUID so AppModel's pending-
                // for-summary buffer can update by id.
                guard let idx = transcript.lastIndex(where: { $0.id == existing.id }) else { continue }
                transcript[idx] = TranscriptSegment(
                    id: existing.id,
                    source: .system,
                    speaker: incoming.speaker,
                    text: incoming.text,
                    startTime: min(existing.startTime, incoming.startTime),
                    endTime: max(existing.endTime, incoming.endTime),
                    isFinal: incoming.isFinal || existing.isFinal,
                    confidence: incoming.confidence,
                    isConfirmed: existing.isConfirmed || incoming.isConfirmed
                )
                return .replaced(previousID: existing.id)
            }
        }
        return nil
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
