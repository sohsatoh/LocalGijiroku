import Foundation

/// Renders a `Session` as Markdown using either a custom template from
/// `SummaryStyle.exportTemplate` or the built-in default.
///
/// Supported placeholders inside the template (each replaced verbatim by the
/// rendered content — no escaping, since the output is Markdown):
///   - `{{title}}`     session title
///   - `{{date}}`      session start in `yyyy-MM-dd HH:mm`
///   - `{{duration}}`  e.g. `45m 12s` or `1h 23m`
///   - `{{summary}}`   `### section` headers + bullets from CumulativeSummary
///   - `{{actions}}`   action items only, no kind prefix
///   - `{{decisions}}` decisions only
///   - `{{questions}}` questions only
///   - `{{suggestions}}` AI-proposed agenda items, no kind prefix
///   - `{{topics}}`    legacy alias for `{{suggestions}}` (kept for any
///                     user-edited template referring to the old name)
///   - `{{events}}`    every event with a `[kind]` prefix
///   - `{{transcript}}` every transcript segment
public enum MarkdownExporter {
    /// Default template used when `SummaryStyle.exportTemplate` is empty.
    /// Transcript is omitted on purpose — the raw JSON still has it and the
    /// expected "share this meeting note" use case is summary + tasks.
    public static let defaultTemplate: String = """
    # {{title}}

    _{{date}} · {{duration}}_

    ## Summary

    {{summary}}

    ## AI Suggestions

    {{suggestions}}

    ## Action Items

    {{actions}}

    ## Decisions

    {{decisions}}

    ## Questions

    {{questions}}
    """

    public static func render(_ session: Session, style: SummaryStyle = .builtin) -> String {
        let template = style.exportTemplate.isEmpty ? defaultTemplate : style.exportTemplate
        let placeholders: [String: String] = [
            "title": session.title,
            "date": formatDate(session.startedAt),
            "duration": formatDuration(from: session.startedAt, to: session.endedAt),
            "summary": renderSummary(session.summary),
            // Both placeholders alias the same content so user-edited
            // templates with the older `{{topics}}` keyword keep working.
            "suggestions": renderEvents(session.events, only: .agendaSuggestion, includeKind: false),
            "topics": renderEvents(session.events, only: .agendaSuggestion, includeKind: false),
            "actions": renderEvents(session.events, only: .action, includeKind: false),
            "decisions": renderEvents(session.events, only: .decision, includeKind: false),
            "questions": renderEvents(session.events, only: .question, includeKind: false),
            "events": renderEvents(session.events, only: nil, includeKind: true),
            "transcript": renderTranscript(session.transcript),
        ]
        var out = template
        for (key, value) in placeholders {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func formatDuration(from start: Date, to end: Date?) -> String {
        guard let end else { return "" }
        let total = max(0, Int(end.timeIntervalSince(start)))
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        if m < 60 { return "\(m)m \(s)s" }
        let h = m / 60
        let mr = m % 60
        return "\(h)h \(mr)m"
    }

    private static func renderSummary(_ summary: CumulativeSummary) -> String {
        guard !summary.sections.isEmpty else { return "_(none)_" }
        var lines: [String] = []
        for section in summary.sections {
            lines.append("### \(section.title)")
            for bullet in section.bullets {
                lines.append("- \(bullet)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderEvents(_ events: [MeetingEvent], only kind: MeetingEvent.Kind?, includeKind: Bool) -> String {
        let filtered = kind.map { k in events.filter { $0.kind == k } } ?? events
        guard !filtered.isEmpty else { return "_(none)_" }
        return filtered.map { ev in
            let prefix = includeKind ? "[\(ev.kind.rawValue)] " : ""
            let owner = ev.owner.map { " (@\($0))" } ?? ""
            let due = ev.dueDate.map { " — due \($0)" } ?? ""
            // Resolved items render with ~strikethrough~ markdown so the
            // exported note matches what the user sees in-app.
            let body = ev.resolved ? "~~\(ev.text)~~" : ev.text
            let suffix = ev.resolved ? " ✓" : ""
            // Indented "→ answer" line under the question / topic so the
            // resolution stays visually attached to its event in the
            // exported markdown.
            let resolutionLine: String
            if let r = ev.resolution, !r.isEmpty {
                resolutionLine = "\n  → \(r)"
            } else {
                resolutionLine = ""
            }
            return "- \(prefix)\(body)\(owner)\(due)\(suffix)\(resolutionLine)"
        }.joined(separator: "\n")
    }

    private static func renderTranscript(_ transcript: [TranscriptSegment]) -> String {
        guard !transcript.isEmpty else { return "_(none)_" }
        return transcript.map { seg in
            "- [\(seg.source.rawValue)] \(seg.text)"
        }.joined(separator: "\n")
    }
}
