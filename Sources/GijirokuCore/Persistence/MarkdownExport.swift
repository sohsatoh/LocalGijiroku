import Foundation

/// Markdown rendering shared by the file exporter and the in-app Markdown
/// pane viewer. Keeping these in one place means the preview and the actual
/// exported file can never drift in format.
public enum MarkdownExport {
    public static func summary(_ summary: CumulativeSummary) -> String {
        var out = ""
        for section in summary.sections {
            out += "### \(section.title)\n"
            for bullet in section.bullets {
                out += "- \(bullet)\n"
            }
            out += "\n"
        }
        return out
    }

    public static func events(_ events: [MeetingEvent]) -> String {
        var out = ""
        for event in events {
            let owner = event.owner.map { " (@\($0))" } ?? ""
            let due = event.dueDate.map { " — due \($0)" } ?? ""
            out += "- [\(event.kind.rawValue)] \(event.text)\(owner)\(due)\n"
        }
        return out
    }

    public static func transcript(_ segments: [TranscriptSegment]) -> String {
        var out = ""
        for seg in segments {
            out += "- [\(seg.source.rawValue)] \(seg.text)\n"
        }
        return out
    }

    public static func sessionDocument(_ session: Session) -> String {
        var out = "# \(session.title)\n\n"
        out += "_\(ISO8601DateFormatter().string(from: session.startedAt))_\n\n"

        out += "## Summary\n\n"
        out += summary(session.summary)

        if !session.events.isEmpty {
            out += "## Events\n\n"
            out += events(session.events)
            out += "\n"
        }

        out += "## Transcript\n\n"
        out += transcript(session.transcript)
        return out
    }
}
