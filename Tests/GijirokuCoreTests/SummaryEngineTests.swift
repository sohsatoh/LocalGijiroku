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

@Test func appendDeltaPromptSendsTitlesOnlyNotBullets() {
    // The whole point of appendDelta is to keep per-turn input cost
    // constant by NEVER sending the bullet payload back to the LLM.
    let messages = SummaryPrompt.appendDelta(
        existingSectionTitles: ["プロジェクトX 進捗", "採用方針"],
        transcriptDelta: "[A] 来週末リリース",
        language: "Japanese"
    )
    #expect(messages.count == 2)
    let user = messages[1].content
    #expect(user.contains("プロジェクトX 進捗"))
    #expect(user.contains("採用方針"))
    #expect(user.contains("[A] 来週末リリース"))
}

@Test func appendDeltaPromptHandlesEmptySectionList() {
    let messages = SummaryPrompt.appendDelta(
        existingSectionTitles: [],
        transcriptDelta: "[A] hello",
        language: "Japanese"
    )
    let user = messages[1].content
    #expect(user.contains("no sections yet"))
}

@Test func parseUpdatesAcceptsEnvelope() throws {
    let input = """
    {"updates":[{"section":"プロジェクトX 進捗","bullets":["来週末リリース"]}]}
    """
    let updates = try SummaryEngine.parseUpdates(response: input)
    #expect(updates.count == 1)
    #expect(updates[0].section == "プロジェクトX 進捗")
    #expect(updates[0].bullets == ["来週末リリース"])
}

@Test func parseUpdatesAcceptsTopLevelArray() throws {
    let input = """
    [{"section":"A","bullets":["a"]},{"section":"B","bullets":["b1","b2"]}]
    """
    let updates = try SummaryEngine.parseUpdates(response: input)
    #expect(updates.count == 2)
    #expect(updates[1].bullets.count == 2)
}

@Test func parseUpdatesDropsEmptyBulletEntries() throws {
    // A header-only update would result in an empty section being inserted
    // into the summary on apply, which is just noise.
    let input = """
    {"updates":[{"section":"X","bullets":[]},{"section":"Y","bullets":["y1"]}]}
    """
    let updates = try SummaryEngine.parseUpdates(response: input)
    #expect(updates.count == 1)
    #expect(updates[0].section == "Y")
}

@Test func parseUpdatesEmptyIsValid() throws {
    let updates = try SummaryEngine.parseUpdates(response: #"{"updates":[]}"#)
    #expect(updates.isEmpty)
}

@Test func applyUpdatesAppendsToExistingSectionByTitle() {
    let existing = CumulativeSummary(sections: [
        .init(title: "プロジェクトX 進捗", bullets: ["初期計画固まる"]),
    ])
    let updates = [SummaryUpdate(section: "プロジェクトX 進捗", bullets: ["来週末リリース"])]
    let result = SummaryEngine.applyUpdates(updates, to: existing)
    #expect(result.sections.count == 1)
    #expect(result.sections[0].bullets == ["初期計画固まる", "来週末リリース"])
}

@Test func applyUpdatesCreatesNewSectionWhenTitleUnknown() {
    let existing = CumulativeSummary(sections: [
        .init(title: "A", bullets: ["a"]),
    ])
    let updates = [SummaryUpdate(section: "B", bullets: ["b"])]
    let result = SummaryEngine.applyUpdates(updates, to: existing)
    #expect(result.sections.count == 2)
    #expect(result.sections[1].title == "B")
}

@Test func applyUpdatesDedupesBulletsAcrossTurns() {
    // The LLM re-emits a bullet that's already in the section (small model
    // mistakenly forgetting it asked for "only NEW bullets"). The cross-
    // section dedup pass in applyUpdates should drop the duplicate.
    let existing = CumulativeSummary(sections: [
        .init(title: "X", bullets: ["来週末リリース"]),
    ])
    let updates = [SummaryUpdate(section: "X", bullets: ["来週末リリース", "追加検証必要"])]
    let result = SummaryEngine.applyUpdates(updates, to: existing)
    #expect(result.sections.count == 1)
    #expect(result.sections[0].bullets == ["来週末リリース", "追加検証必要"])
}

@Test func fullPassPromptIncludesTranscript() {
    let messages = SummaryPrompt.fullPass(
        transcript: "[A] hello world",
        language: "Japanese"
    )
    #expect(messages.count == 2)
    #expect(messages[1].content.contains("[A] hello world"))
    #expect(messages[0].content.contains("Japanese"))
}
