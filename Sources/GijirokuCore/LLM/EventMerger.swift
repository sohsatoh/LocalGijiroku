import Foundation

/// Merges a freshly-extracted batch of `MeetingEvent`s into an existing list,
/// folding duplicates and upgrading entries when newer extractions add
/// detail (owner, due date) for an event that was already recorded.
///
/// Identity is decided by `(kind, similarityCheck)`:
///   - same `kind`, AND
///   - one of: strict containment, or directional bigram overlap ≥
///     `similarityThreshold` (default 0.7)
///
/// The directional bigram check is what catches the real-world failure
/// mode the original "first-N-chars normalized key" missed: Whisper
/// transcribed the same word two different ways across cycles
/// ("リテラシー" vs "リテラー"), the prefix keys diverged at character 6,
/// and the deduper appended a second event for the same content.
public struct EventMerger {
    public struct Config: Sendable {
        /// Char-bigram directional overlap threshold for treating two
        /// same-kind events as the same. The "smaller" side has to have
        /// ≥ this fraction of its bigrams present in the longer side.
        public var similarityThreshold: Float
        /// Below this bigram count on the shorter side, fall back to
        /// substring containment only — prevents spurious 1-shared-bigram
        /// matches between very short events.
        public var minBigramsForSimilarity: Int

        public init(
            similarityThreshold: Float = 0.7,
            minBigramsForSimilarity: Int = 4
        ) {
            self.similarityThreshold = similarityThreshold
            self.minBigramsForSimilarity = minBigramsForSimilarity
        }
    }

    public let config: Config

    public init(config: Config = .init()) {
        self.config = config
    }

    public func merge(_ newEvents: [MeetingEvent], into existing: inout [MeetingEvent]) {
        for new in newEvents {
            if let idx = findMatch(for: new, in: existing) {
                existing[idx] = Self.merged(into: existing[idx], from: new)
            } else {
                existing.append(new)
            }
        }
    }

    private func findMatch(for event: MeetingEvent, in list: [MeetingEvent]) -> Int? {
        let needleBigrams = Self.charBigrams(of: Self.normalize(event.text))
        for (idx, candidate) in list.enumerated() {
            guard candidate.kind == event.kind else { continue }
            if Self.isSameContent(
                event.text,
                candidate.text,
                aBigrams: needleBigrams,
                threshold: config.similarityThreshold,
                minBigrams: config.minBigramsForSimilarity
            ) {
                return idx
            }
        }
        return nil
    }

    /// Two event texts likely describe the same agenda item / question /
    /// decision / action. Tries (in order):
    ///   1. Normalized equality.
    ///   2. Strict substring containment in either direction (Whisper
    ///      extended or truncated the text across cycles).
    ///   3. Directional bigram containment on the SHORTER side ≥ threshold.
    ///      Catches single-character drift like リテラシー → リテラー.
    static func isSameContent(
        _ a: String,
        _ b: String,
        aBigrams: Set<String>? = nil,
        threshold: Float,
        minBigrams: Int
    ) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        if na.isEmpty || nb.isEmpty { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        let aSet = aBigrams ?? charBigrams(of: na)
        let bSet = charBigrams(of: nb)
        let smaller = min(aSet.count, bSet.count)
        guard smaller >= minBigrams else { return false }
        let inter = aSet.intersection(bSet).count
        return Float(inter) / Float(smaller) >= threshold
    }

    /// Merges `incoming` into `current`, keeping the original `id` /
    /// `detectedAt` (so the UI ordering is stable) but adopting newly-known
    /// owner / due fields, the longer / more recent text, and any
    /// resolved=true status the LLM has assigned. Once an event is marked
    /// resolved it stays resolved — later re-emissions can't accidentally
    /// re-open it.
    static func merged(into current: MeetingEvent, from incoming: MeetingEvent) -> MeetingEvent {
        let text: String = {
            if incoming.text.count >= current.text.count { return incoming.text }
            return current.text
        }()
        // Resolution: take the latest non-empty one. If a later turn
        // refines the answer ("by Friday" → "by Friday EOD"), we want
        // the refinement to win.
        let resolution = incoming.resolution ?? current.resolution
        return MeetingEvent(
            id: current.id,
            kind: current.kind,
            text: text,
            owner: incoming.owner ?? current.owner,
            dueDate: incoming.dueDate ?? current.dueDate,
            detectedAt: current.detectedAt,
            resolved: current.resolved || incoming.resolved,
            resolution: resolution
        )
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .lowercased()
    }

    /// Character bigram set. Used for the directional containment check —
    /// works the same way as `TranscriptDeduper.charBigrams` but kept
    /// private to this type so the events layer has no cross-module
    /// dependency.
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
}
