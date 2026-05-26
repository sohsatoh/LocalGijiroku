import Foundation

/// Shared transcript-to-prompt formatter used by SummaryEngine and
/// EventExtractor. Both need to feed the LLM a compact representation of the
/// transcript that includes speaker information (when diarization assigned
/// a stable label) so the model can attribute decisions / actions / topics
/// to a specific participant.
///
/// Format per line:
///   `[<speaker>] <text>`  — when diarization produced a stable label
///   `<text>`              — when no speaker is known
///
/// We deliberately do NOT fall back to the `AudioSource.rawValue`
/// (`microphone` / `system`). Those are capture-layer concerns, not speakers
/// — feeding them as `[system]` previously caused LLMs to echo `[system]`
/// prefixes into summary bullets, which is meaningless to the reader.
public enum TranscriptFormatting {
    public static func toPromptLines(_ segments: [TranscriptSegment]) -> String {
        segments.map { seg in
            if let label = seg.speaker, !label.isEmpty {
                return "[\(label)] \(seg.text)"
            }
            return seg.text
        }
        .joined(separator: "\n")
    }
}
