import Testing
import Foundation
@testable import GijirokuCore

private let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)

private func sampleSession(events: [MeetingEvent] = [], summary: CumulativeSummary = CumulativeSummary(), title: String = "Demo") -> Session {
    Session(
        title: title,
        startedAt: fixedStart,
        endedAt: fixedStart.addingTimeInterval(45 * 60 + 12),
        transcript: [.init(source: .microphone, text: "hello", startTime: fixedStart, endTime: fixedStart.addingTimeInterval(2), isFinal: true)],
        summary: summary,
        events: events
    )
}

@Test func defaultTemplateRendersExpectedSections() {
    let session = sampleSession(
        events: [
            .init(kind: .action, text: "ship it", owner: "alice", dueDate: "2026-06-01"),
            .init(kind: .decision, text: "go ahead"),
            .init(kind: .question, text: "what about edge case?"),
        ],
        summary: CumulativeSummary(sections: [.init(title: "Topic", bullets: ["point a", "point b"])])
    )
    let md = MarkdownExporter.render(session)
    #expect(md.contains("# Demo"))
    #expect(md.contains("## Summary"))
    #expect(md.contains("### Topic"))
    #expect(md.contains("- point a"))
    #expect(md.contains("- point b"))
    #expect(md.contains("## Action Items"))
    #expect(md.contains("- ship it (@alice) — due 2026-06-01"))
    #expect(md.contains("## Decisions"))
    #expect(md.contains("- go ahead"))
    #expect(md.contains("## Questions"))
    #expect(md.contains("- what about edge case?"))
}

@Test func customTemplateSubstitutesPlaceholders() {
    let style = SummaryStyle(exportTemplate: """
    # {{title}}

    {{summary}}

    ## TODOs
    {{actions}}

    ## Raw events
    {{events}}
    """)
    let session = sampleSession(
        events: [
            .init(kind: .action, text: "do thing", owner: "bob"),
            .init(kind: .decision, text: "decide"),
        ],
        summary: CumulativeSummary(sections: [.init(title: "S", bullets: ["b"])])
    )
    let md = MarkdownExporter.render(session, style: style)
    #expect(md.contains("# Demo"))
    #expect(md.contains("### S"))
    #expect(md.contains("- b"))
    #expect(md.contains("## TODOs"))
    #expect(md.contains("- do thing (@bob)"))
    #expect(md.contains("## Raw events"))
    #expect(md.contains("- [action] do thing"))
    #expect(md.contains("- [decision] decide"))
    // Custom template shouldn't smuggle in the default section headers.
    #expect(!md.contains("## Action Items"))
    #expect(!md.contains("## Decisions"))
}

@Test func emptyCategoriesRenderAsNoneMarker() {
    let session = sampleSession(events: [.init(kind: .action, text: "only an action")])
    let md = MarkdownExporter.render(session)
    // Decisions and Questions sections exist but are empty -> "_(none)_"
    let decisionsRange = md.range(of: "## Decisions")
    #expect(decisionsRange != nil)
    let afterDecisions = md[decisionsRange!.upperBound...]
    #expect(afterDecisions.contains("_(none)_"))
}

@Test func durationFormatsHoursMinutesSeconds() {
    let style = SummaryStyle(exportTemplate: "{{duration}}")
    // 45m 12s
    let md1 = MarkdownExporter.render(sampleSession(), style: style).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(md1 == "45m 12s")
    // 1h 5m for a longer session
    let longer = Session(
        title: "L",
        startedAt: fixedStart,
        endedAt: fixedStart.addingTimeInterval(3_900),
        transcript: [], summary: CumulativeSummary(), events: []
    )
    let md2 = MarkdownExporter.render(longer, style: style).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(md2 == "1h 5m")
}

@Test func summaryStyleExportTemplateIsBackwardsCompatibleOnDecode() throws {
    // Old JSON (saved by a previous build) doesn't carry the field.
    let oldJSON = """
    {
      "extraSummaryInstructions": "focus",
      "extraEventInstructions": "",
      "maxBulletWords": 12,
      "maxSections": 0
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(SummaryStyle.self, from: oldJSON)
    #expect(decoded.exportTemplate == "")
    #expect(decoded.maxBulletWords == 12)
    #expect(decoded.extraSummaryInstructions == "focus")
}

@Test func summaryStyleMergingPrefersOverrideTemplate() {
    let user = SummaryStyle(exportTemplate: "user-template")
    let project = SummaryStyle(exportTemplate: "project-template")
    let resolved = SummaryStyle.resolved(user: user, project: project)
    #expect(resolved.exportTemplate == "project-template")

    let resolvedNoProject = SummaryStyle.resolved(user: user, project: SummaryStyle())
    #expect(resolvedNoProject.exportTemplate == "user-template")
}
