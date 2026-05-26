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
        /// Fraction of the shorter segment's duration that has to be
        /// covered by the other for the deduper to treat them as the
        /// same audio region. Robust against text drift between
        /// Whisper cycles: when "都がですね10年ぶりに" and "1年ぶりに
        /// 1、6月期…" share the same audio span but split it into
        /// completely different text, no string-similarity metric
        /// touches them — the time-overlap signal does.
        public var timeOverlapThreshold: Float

        public init(
            lookbackWindow: Int = 8,
            similarityThreshold: Float = 0.7,
            maxStartTimeDelta: TimeInterval = 12,
            crossSourceBleedSuppression: Bool = true,
            crossSourceTimeDelta: TimeInterval = 6,
            subsumptionThreshold: Float = 0.7,
            timeOverlapThreshold: Float = 0.5
        ) {
            self.lookbackWindow = lookbackWindow
            self.similarityThreshold = similarityThreshold
            self.maxStartTimeDelta = maxStartTimeDelta
            self.crossSourceBleedSuppression = crossSourceBleedSuppression
            self.crossSourceTimeDelta = crossSourceTimeDelta
            self.subsumptionThreshold = subsumptionThreshold
            self.timeOverlapThreshold = timeOverlapThreshold
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
        //
        // Match check is `mergeSignal` — symmetric Jaccard OR directional
        // bigram containment, whichever is higher. The directional half
        // catches the asymmetric-refinement case symmetric similarity used
        // to miss: when Whisper re-emits a short utterance as a slightly
        // longer / slightly different one ("日程 新山貴です" →
        // "日程 新山貴樹です", "10年ぶり…" → "1年ぶり…"), symmetric
        // Jaccard sinks below 0.7 because the union inflates with the
        // longer side's unique bigrams, but the shorter side's bigrams
        // are still ≥ 70 % present in the longer side. Without this the
        // user kept seeing two near-duplicate rows because primary match
        // missed, and the post-merge sweep never ran.
        // Match criteria (any one is sufficient):
        //   1. Significant TIME OVERLAP — same audio decoded by different
        //      rolling-window cycles. Text can drift arbitrarily ("10年"
        //      → "1年", chunk boundaries shift), but the start/end times
        //      stay anchored to the same audio sample range. This is the
        //      most robust signal for the rolling-decoder case.
        //   2. mergeSignal ≥ threshold — symmetric Jaccard or directional
        //      bigram containment. Catches cases where time-stamps drift
        //      but text overlaps substantially.
        //   3. Time delta within `maxStartTimeDelta` AND mergeSignal
        //      meets threshold — the original same-source same-region
        //      check, kept as a fallback.
        let incomingBigrams = Self.charBigrams(of: incoming.text)
        let lookbackStart = max(0, transcript.count - config.lookbackWindow)
        var matchingIndices: [Int] = []
        for i in lookbackStart..<transcript.count {
            let existing = transcript[i]
            guard existing.source == incoming.source else { continue }
            let overlapRatio = Self.timeOverlapRatio(existing, incoming)
            let timeDelta = abs(existing.startTime.timeIntervalSince(incoming.startTime))
            // Time-overlap path: ≥ 50 % of the shorter segment's duration
            // is shared with the other → same audio. No text similarity
            // needed; chunking can shift wildly between cycles.
            let timeOverlapMatch = overlapRatio >= config.timeOverlapThreshold
            // Text-similarity path: same source within the time gate AND
            // the merge signal passes.
            let textSignal = (timeDelta <= config.maxStartTimeDelta)
                ? Self.mergeSignal(existing: existing.text, incoming: incoming.text, incomingBigrams: incomingBigrams)
                : 0
            let textMatch = textSignal >= config.similarityThreshold
            guard timeOverlapMatch || textMatch else { continue }
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
            // smartConcatMerge handles the rolling-window overlap case:
            // when one's tail and the other's head share substantial
            // content (the LCS), splice them so neither side's unique
            // segment of audio is dropped. Falls back to "longer wins"
            // for non-boundary overlaps where splicing would risk
            // mid-sentence corruption. Chronological order is implied
            // by feeding `primary` (older / lower index) first.
            mergedText = Self.smartConcatMerge(primary.text, incoming.text)
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

    /// Intersection / shorter-span ratio of two segments' time ranges.
    /// 0 when disjoint, 1 when one fully covers the other. Used as the
    /// primary "same audio" signal — robust against the text drift the
    /// rolling Whisper decoder produces between cycles.
    static func timeOverlapRatio(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Float {
        let aSpan = a.endTime.timeIntervalSince(a.startTime)
        let bSpan = b.endTime.timeIntervalSince(b.startTime)
        guard aSpan > 0, bSpan > 0 else { return 0 }
        let overlapStart = max(a.startTime, b.startTime)
        let overlapEnd = min(a.endTime, b.endTime)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        guard overlap > 0 else { return 0 }
        return Float(overlap / min(aSpan, bSpan))
    }

    /// Merge two strings that represent overlapping audio decoded into
    /// slightly different text by different rolling-window cycles.
    /// `a` is the older (transcript-resident) text, `b` is the incoming
    /// one. Uses the longest common substring (LCS) to splice the unique
    /// prefix of one and unique suffix of the other when the LCS sits
    /// at the boundary (typical "rolling overlap" pattern). Falls back
    /// to "longer wins, ties go to incoming" when the LCS is too short
    /// or sits in the middle — incoming wins ties because the newer
    /// inference cycle had more decoder context.
    static func smartConcatMerge(_ a: String, _ b: String) -> String {
        if a == b { return a }
        if a.contains(b) { return a }
        if b.contains(a) { return b }
        let (lcsLen, aOffset, bOffset) = longestCommonSubstring(a, b)
        // Require at least 3 chars of overlap to attempt a splice — keeps
        // unrelated short coincidences from triggering concatenation.
        guard lcsLen >= 3 else {
            return b.count >= a.count ? b : a
        }
        let aChars = Array(a)
        let bChars = Array(b)
        let aTail = aChars.count - (aOffset + lcsLen)
        let bHead = bOffset
        let aHead = aOffset
        let bTail = bChars.count - (bOffset + lcsLen)
        // Strict boundary: LCS must sit at the EXACT end of one side and
        // the EXACT start of the other to count as a clean rolling
        // overlap. Any unique-content prefix on the "next" side (e.g.
        // "10年" → "1年" — the leading digit is different content, not
        // a punctuation tag-along) means the LCS isn't a chronological
        // boundary; it's two different decodings of the same audio,
        // and splicing would preserve a misheard prefix or suffix from
        // the older version. Fall through to "longer wins" in that case.
        // a's LCS at end + b's LCS at start → a comes first, append b's
        // tail.
        if aTail == 0, bHead == 0 {
            return String(aChars.prefix(aOffset + lcsLen)) + String(bChars.suffix(bTail))
        }
        // b's LCS at end + a's LCS at start → b comes first, append a's
        // tail.
        if bTail == 0, aHead == 0 {
            return String(bChars.prefix(bOffset + lcsLen)) + String(aChars.suffix(aTail))
        }
        // LCS interior of either side, or unique content on the "wrong"
        // edge — splicing risks preserving an older misheard fragment.
        // Prefer the longer text and let the sweep prune the other.
        // Ties go to incoming (newer) on the theory that the more recent
        // inference cycle had more decoder context.
        return b.count >= a.count ? b : a
    }

    /// Returns (lcs.length, a's start index of LCS, b's start index of LCS).
    /// Classic O(n*m) dynamic programming over character arrays, which is
    /// fine for transcript-segment-sized strings (< 100 chars each).
    static func longestCommonSubstring(_ a: String, _ b: String) -> (length: Int, aOffset: Int, bOffset: Int) {
        let aChars = Array(a)
        let bChars = Array(b)
        guard !aChars.isEmpty, !bChars.isEmpty else { return (0, 0, 0) }
        var dp = Array(repeating: Array(repeating: 0, count: bChars.count + 1), count: aChars.count + 1)
        var best = 0
        var bestAEnd = 0
        var bestBEnd = 0
        for i in 1...aChars.count {
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                    if dp[i][j] > best {
                        best = dp[i][j]
                        bestAEnd = i
                        bestBEnd = j
                    }
                }
            }
        }
        return (best, bestAEnd - best, bestBEnd - best)
    }

    /// Merge-eligibility signal between an existing transcript entry and
    /// an incoming segment. Combines two views into one ratio:
    ///   - **symmetric Jaccard** via `similarity(_:_:)`, which already
    ///     short-circuits to 1.0 on strict substring containment and is
    ///     well-tuned for short utterances of comparable length;
    ///   - **directional bigram containment** — what fraction of the
    ///     SHORTER side's bigrams appear in the longer side. Catches the
    ///     asymmetric-refinement case (short fragment refined into a
    ///     longer / slightly different sentence) symmetric similarity
    ///     misses because the union inflates with the long side's unique
    ///     bigrams.
    /// Returns the max of the two so any signal high enough triggers a
    /// merge. The min-bigram-count gate (`shorter ≥ 3`) prevents
    /// 1-bigram trivial matches like "今日" matching every long sentence
    /// containing "今日" — the time-delta gate at the call site does
    /// most of that work, but the bigram floor is cheap insurance.
    static func mergeSignal(
        existing: String,
        incoming: String,
        incomingBigrams: Set<String>?
    ) -> Float {
        let sym = Self.similarity(existing, incoming)
        let existingBigrams = Self.charBigrams(of: existing)
        let incomingBigrams = incomingBigrams ?? Self.charBigrams(of: incoming)
        let smaller = min(existingBigrams.count, incomingBigrams.count)
        guard smaller >= 3 else { return sym }
        let inter = existingBigrams.intersection(incomingBigrams).count
        let directional = Float(inter) / Float(smaller)
        return max(sym, directional)
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
