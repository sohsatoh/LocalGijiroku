import Testing
import Foundation
@testable import GijirokuCore

@Test func parsesPlainSummaryJSON() throws {
    let json = """
    {"sections":[{"title":"Roadmap","bullets":["Q2 ship","Q3 hire"]},{"title":"Budget","bullets":["Cut 10%"]}]}
    """
    let summary = try SummaryEngine.parse(response: json)
    #expect(summary.sections.count == 2)
    #expect(summary.sections[0].title == "Roadmap")
    #expect(summary.sections[0].bullets == ["Q2 ship", "Q3 hire"])
    #expect(summary.sections[1].title == "Budget")
}

@Test func parsesSummaryWithMarkdownFences() throws {
    let json = """
    ```json
    {"sections":[{"title":"X","bullets":["a"]}]}
    ```
    """
    let summary = try SummaryEngine.parse(response: json)
    #expect(summary.sections.count == 1)
    #expect(summary.sections[0].bullets == ["a"])
}

@Test func stripsFencesWithLanguageTag() {
    let raw = "```\n{\"sections\":[]}\n```"
    #expect(SummaryEngine.stripJSONFences(raw) == "{\"sections\":[]}")
}

@Test func parsesEmptySections() throws {
    let summary = try SummaryEngine.parse(response: "{\"sections\":[]}")
    #expect(summary.sections.isEmpty)
}

@Test func summaryPromptIncludesExistingAndDelta() {
    let existing = CumulativeSummary(sections: [.init(title: "Old", bullets: ["x"])])
    let messages = SummaryPrompt.update(existing: existing, transcriptDelta: "hello world", language: "Japanese")
    #expect(messages.count == 2)
    #expect(messages[0].role == .system)
    #expect(messages[0].content.contains("Japanese"))
    #expect(messages[1].content.contains("hello world"))
    #expect(messages[1].content.contains("Old"))
}
