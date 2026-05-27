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

    /// Concatenated confirmed text for the turn, joined with the same
    /// smart concat the UI uses for paragraphs (ASCII word boundary →
    /// space, CJK boundary → no separator). Used for plain-text exports
    /// and tests; the live UI consumes `paragraphs` instead.
    public var text: String {
        TranscriptTurn.smartConcat(segments.map { $0.text })
    }

    /// Split the confirmed segment run into paragraphs at sentence-ending
    /// punctuation (。!?.！？), so the UI can render multiple paragraphs
    /// inside a single speaker turn instead of one wall of text.
    ///
    /// Why on `TranscriptTurn` rather than the view: this is data shape,
    /// not styling — the headless CLI runner and tests want the same
    /// segmentation, and it lets the view stay declarative.
    public var paragraphs: [String] {
        guard !segments.isEmpty else { return [] }
        var paragraphs: [String] = []
        var current: [String] = []
        for seg in segments {
            current.append(seg.text)
            if TranscriptTurn.endsWithTerminalPunctuation(seg.text) {
                paragraphs.append(TranscriptTurn.smartConcat(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            paragraphs.append(TranscriptTurn.smartConcat(current))
        }
        return paragraphs
    }

    /// True when `s`'s last non-whitespace character is a sentence
    /// terminator. Covers both Japanese (。、！？) and ASCII (.!?).
    /// 、 isn't included — it's a mid-sentence comma, not a paragraph
    /// boundary.
    static func endsWithTerminalPunctuation(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return "。．！？!?.".contains(last)
    }

    /// Concatenate consecutive segment texts with a single rule:
    /// insert a space only at an ASCII word boundary (both adjacent
    /// characters are ASCII letters / digits). CJK gets concatenated
    /// directly, because joining "今日は" + "元気です" with " " produces
    /// "今日は 元気です" which reads wrong in Japanese.
    static func smartConcat(_ texts: [String]) -> String {
        var result = ""
        for raw in texts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
                continue
            }
            // ASCII word boundary needs a space; CJK doesn't.
            let prev = result.last
            let next = trimmed.first
            let needsSpace =
                (prev?.isLetter == true || prev?.isNumber == true) &&
                (next?.isLetter == true || next?.isNumber == true) &&
                prev?.isASCII == true && next?.isASCII == true
            result += needsSpace ? " \(trimmed)" : trimmed
        }
        return result
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
///   - a `TranscriptHeading.startTime` falling between two otherwise-
///     mergeable segments — the heading is a section divider, so a
///     continuous run of speech that straddles it must split into the
///     "before" and "after" halves. Without this, the turns layout
///     would render a single block with the heading orphaned beside it.
public enum TranscriptTurnGrouping {
    public static let defaultMaxIntraTurnGap: TimeInterval = 5

    public static func turns(
        from segments: [TranscriptSegment],
        liveTail: [AudioSource: TranscriptSegment] = [:],
        headings: [TranscriptHeading] = [],
        maxIntraTurnGap: TimeInterval = defaultMaxIntraTurnGap
    ) -> [TranscriptTurn] {
        // Order matters: feed segments in chronological order regardless of
        // how the caller assembled them. The deduper may reorder when an
        // older segment lands after a newer one due to system / mic
        // interleaving.
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        let headingTimes = headings.map { $0.startTime }

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
                // Heading boundary check: if any heading's anchor falls
                // strictly between `last.endTime` and `seg.startTime`,
                // the new segment starts a fresh section and must not
                // merge into the in-progress turn even when the source/
                // speaker/gap criteria all say "same turn".
                let crossesHeading = headingTimes.contains { h in
                    h > last.endTime && h <= seg.startTime
                }
                if !crossesHeading && sameSource && sameSpeaker && gap <= maxIntraTurnGap {
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
