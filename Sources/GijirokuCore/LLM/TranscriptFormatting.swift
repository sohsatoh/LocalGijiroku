import Foundation

/// Shared transcript-to-prompt formatter used by SummaryEngine and
/// EventExtractor. Both need to feed the LLM a compact representation of the
/// transcript that includes speaker information (when diarization assigned
/// a stable label) so the model can attribute decisions / actions / topics
/// to a specific participant.
///
/// Format per line:
///   `[<speaker or source>] <text>`
///
/// Examples:
///   `[Speaker_1] We should ship next week.`
///   `[microphone] (when no diarization label is available)`
public enum TranscriptFormatting {
    public static func toPromptLines(_ segments: [TranscriptSegment]) -> String {
        segments.map { seg in
            let label = seg.speaker?.nilIfEmpty ?? seg.source.rawValue
            return "[\(label)] \(seg.text)"
        }
        .joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
