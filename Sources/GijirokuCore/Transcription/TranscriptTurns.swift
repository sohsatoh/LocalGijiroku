import Foundation

/// A contiguous run of segments treated as one speaker turn for display.
/// The UI renders each turn as a single block (one speaker label + flowing
/// text), Notion-style, instead of one row per Whisper segment.
public struct TranscriptTurn: Identifiable, Sendable, Equatable {
    /// Stable enough for SwiftUI's diffing: derived from the source and the
    /// first segment's id. Reusing the first segment's id means the turn's
    /// SwiftUI identity stays the same even as later confirmed segments
    /// merge into the same block.
    public let id: UUID
    public let source: AudioSource
    public let speaker: String?
    public let segments: [TranscriptSegment]
    public let startTime: Date
    public let endTime: Date
    /// The unconfirmed live tail attached to this turn, if any. Always nil
    /// except on the most recent turn per source — earlier turns are
    /// historical and don't get rewritten by the rolling-window decoder.
    public let liveTail: TranscriptSegment?

    public init(
        id: UUID,
        source: AudioSource,
        speaker: String?,
        segments: [TranscriptSegment],
        startTime: Date,
        endTime: Date,
        liveTail: TranscriptSegment? = nil
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.segments = segments
        self.startTime = startTime
        self.endTime = endTime
        self.liveTail = liveTail
    }

    /// Concatenated confirmed text for the turn. Falls back to a single
    /// space between segments — Whisper's segment splits aren't sentence
    /// boundaries, just decoder chunking, so joining with a space reads
    /// naturally.
    public var text: String {
        segments
            .map { $0.text }
            .joined(separator: " ")
    }
}

/// Pure grouping helper: collapse a chronological transcript + the current
/// live-tail-per-source into Notion-style speaker turns.
///
/// Boundaries between turns:
///   - source change (mic ↔ system)
///   - speaker change (when diarization assigned different labels)
///   - time gap larger than `maxIntraTurnGap` (default 5 s — covers normal
///     intra-utterance pauses but starts a new block when the speaker
///     trails off and someone else picks up)
public enum TranscriptTurnGrouping {
    public static let defaultMaxIntraTurnGap: TimeInterval = 5

    public static func turns(
        from segments: [TranscriptSegment],
        liveTail: [AudioSource: TranscriptSegment] = [:],
        maxIntraTurnGap: TimeInterval = defaultMaxIntraTurnGap
    ) -> [TranscriptTurn] {
        // Order matters: feed segments in chronological order regardless of
        // how the caller assembled them. The deduper may reorder when an
        // older segment lands after a newer one due to system / mic
        // interleaving.
        let sorted = segments.sorted { $0.startTime < $1.startTime }

        var turns: [TranscriptTurn] = []
        var current: [TranscriptSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            turns.append(TranscriptTurn(
                id: first.id,
                source: first.source,
                speaker: first.speaker,
                segments: current,
                startTime: first.startTime,
                endTime: last.endTime
            ))
            current.removeAll(keepingCapacity: true)
        }

        for seg in sorted {
            if let last = current.last {
                let sameSource = last.source == seg.source
                let sameSpeaker = (last.speaker ?? "") == (seg.speaker ?? "")
                let gap = seg.startTime.timeIntervalSince(last.endTime)
                if sameSource && sameSpeaker && gap <= maxIntraTurnGap {
                    current.append(seg)
                    continue
                }
                flush()
            }
            current.append(seg)
        }
        flush()

        // Attach the live tail per source to the LAST turn of that source
        // (the one the speaker is currently extending). If a source has a
        // tail but no confirmed turn yet, synthesise a turn-shell so the
        // first words of a new speaker still appear immediately.
        var attached: Set<AudioSource> = []
        var withTails: [TranscriptTurn] = []
        for turn in turns.reversed() {
            if attached.contains(turn.source) {
                withTails.append(turn)
                continue
            }
            if let tail = liveTail[turn.source] {
                withTails.append(TranscriptTurn(
                    id: turn.id,
                    source: turn.source,
                    speaker: turn.speaker,
                    segments: turn.segments,
                    startTime: turn.startTime,
                    endTime: max(turn.endTime, tail.endTime),
                    liveTail: tail
                ))
                attached.insert(turn.source)
            } else {
                withTails.append(turn)
            }
        }
        var result = Array(withTails.reversed())
        // Sources that have a tail but no confirmed segment yet — start a
        // virtual turn so the UI can show "speech in progress" without
        // waiting for the first confirmed segment.
        for (source, tail) in liveTail where !attached.contains(source) {
            result.append(TranscriptTurn(
                id: tail.id,
                source: source,
                speaker: tail.speaker,
                segments: [],
                startTime: tail.startTime,
                endTime: tail.endTime,
                liveTail: tail
            ))
        }
        return result.sorted { $0.startTime < $1.startTime }
    }
}
