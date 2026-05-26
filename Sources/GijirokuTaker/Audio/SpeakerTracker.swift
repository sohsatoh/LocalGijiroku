import Foundation

/// Cross-window stable labels for speaker diarization.
///
/// SpeakerKit (pyannote) re-runs clustering per audio window, so the
/// "speakerId(0)" string from one window has no relation to "speakerId(0)"
/// from the next. Internal `SpeakerEmbedding` would let us cluster across
/// windows directly, but it's not exposed in the public SpeakerKit API.
///
/// Workaround: WhisperTranscription processes 25-second rolling windows
/// every 5 seconds, so neighboring windows share ~20 seconds of audio.
/// During that overlap the same physical person occupies the same time
/// range, so we can map the new window's local labels to the prior
/// window's labels by computing time overlap between speaker spans.
///
/// The result is "stable" speaker labels ("Speaker 1", "Speaker 2", ...)
/// that persist across windows for the duration of a recording.
actor SpeakerTracker {
    /// One speaker time span in absolute (Date-based) coordinates.
    struct AbsoluteSpan: Sendable, Equatable {
        let start: Date
        let end: Date
        let localLabel: String
    }

    /// Tunable parameters.
    struct Config: Sendable {
        /// Minimum overlap (seconds) required to consider two spans the
        /// same speaker. Below this the new local label gets its own
        /// fresh stable label.
        var minOverlapSeconds: TimeInterval
        /// How long to keep historical spans before pruning, in seconds.
        var historyRetentionSeconds: TimeInterval

        init(minOverlapSeconds: TimeInterval = 0.5, historyRetentionSeconds: TimeInterval = 120) {
            self.minOverlapSeconds = minOverlapSeconds
            self.historyRetentionSeconds = historyRetentionSeconds
        }
    }

    private let config: Config
    /// All previously observed spans, tagged with their assigned stable label.
    private var historicalStableSpans: [(start: Date, end: Date, stable: String)] = []
    /// Monotonic counter for new stable labels.
    private var nextStableID: Int = 0

    init(config: Config = .init()) {
        self.config = config
    }

    /// Resolves the given window's local-label spans into a `local -> stable`
    /// mapping. New local labels that have no significant overlap with any
    /// known stable speaker get a fresh stable label allocated.
    ///
    /// The same mapping is also persisted internally so the next call
    /// (= next window) can match against this window's contribution.
    func resolve(spans: [AbsoluteSpan]) -> [String: String] {
        pruneHistory(now: spans.map(\.end).max() ?? Date())

        // Group input spans by local label to compute per-label overlaps
        // against the historical timeline.
        let localGroups: [String: [AbsoluteSpan]] = Dictionary(grouping: spans, by: \.localLabel)
        // Sort local labels deterministically so allocation order is stable
        // across runs (helps tests and human reading).
        let sortedLocals = localGroups.keys.sorted()

        var result: [String: String] = [:]
        // We allow each stable speaker to be claimed by only one local label
        // in a single window; otherwise two simultaneous speakers in the new
        // window could both grab the same stable label.
        var claimedThisCall = Set<String>()

        for local in sortedLocals {
            guard let myRanges = localGroups[local] else { continue }
            let stable = bestStable(matching: myRanges, excluding: claimedThisCall)
            let assigned: String
            if let s = stable, s.overlap >= config.minOverlapSeconds {
                assigned = s.label
            } else {
                assigned = allocateNewStable()
            }
            claimedThisCall.insert(assigned)
            result[local] = assigned
            for r in myRanges {
                historicalStableSpans.append((r.start, r.end, assigned))
            }
        }

        return result
    }

    /// Clears all state. Call at the start of each session.
    func reset() {
        historicalStableSpans.removeAll()
        nextStableID = 0
    }

    // MARK: - Private

    private func bestStable(
        matching ranges: [AbsoluteSpan],
        excluding excluded: Set<String>
    ) -> (label: String, overlap: TimeInterval)? {
        // Total per-stable overlap with `ranges`.
        var perStable: [String: TimeInterval] = [:]
        for r in ranges {
            for hist in historicalStableSpans where !excluded.contains(hist.stable) {
                let ov = Self.overlapSeconds(
                    aStart: r.start, aEnd: r.end,
                    bStart: hist.start, bEnd: hist.end
                )
                if ov > 0 {
                    perStable[hist.stable, default: 0] += ov
                }
            }
        }
        return perStable.max(by: { $0.value < $1.value })
            .map { (label: $0.key, overlap: $0.value) }
    }

    private func allocateNewStable() -> String {
        let label = "Speaker \(nextStableID + 1)"
        nextStableID += 1
        return label
    }

    private func pruneHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-config.historyRetentionSeconds)
        historicalStableSpans.removeAll { $0.end < cutoff }
    }

    /// Pure helper exposed for testing.
    static func overlapSeconds(aStart: Date, aEnd: Date, bStart: Date, bEnd: Date) -> TimeInterval {
        let start = max(aStart.timeIntervalSinceReferenceDate, bStart.timeIntervalSinceReferenceDate)
        let end = min(aEnd.timeIntervalSinceReferenceDate, bEnd.timeIntervalSinceReferenceDate)
        return max(0, end - start)
    }
}
