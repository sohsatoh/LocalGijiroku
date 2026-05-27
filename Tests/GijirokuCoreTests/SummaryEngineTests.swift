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

@Test func parseUpdatesRepairsBracketSwapMalformedFromSmallModel() throws {
    // Real-world failure from a small LLM: it wrote `}` instead of `]`
    // after the last bullet, leaving the bullets array unclosed inside
    // an already-closed object. The repair pass swaps the trailing
    // bracket trio `}]}` to `]}]` and appends a closing `}` to balance.
    let broken = #"""
    {"updates":[{"section":"坂市総理面会内容","bullets":["細かいチェックが難しいと感じられる","プライバシーの考慮が必須である","セキュリティ上の脆弱性は専門家に確認を依頼すべき","リリース前にセキュリティデビュー用エージェントを実行させる"}]}
    """#
    let updates = try SummaryEngine.parseUpdates(response: broken)
    #expect(updates.count == 1)
    #expect(updates[0].section == "坂市総理面会内容")
    #expect(updates[0].bullets.count == 4)
    #expect(updates[0].bullets.first == "細かいチェックが難しいと感じられる")
}

@Test func parseUpdatesRepairsTruncatedTail() throws {
    // Token-limit truncation: LLM ran out of budget mid-output. Missing
    // the final `]}` to close the bullets array + outer object.
    let truncated = #"{"updates":[{"section":"X","bullets":["a","b","c""#
    let updates = try SummaryEngine.parseUpdates(response: truncated)
    #expect(updates.count == 1)
    #expect(updates[0].bullets == ["a", "b", "c"])
}

@Test func repairUnbalancedJSONLeavesValidUnchanged() {
    let valid = #"{"updates":[{"section":"X","bullets":["a"]}]}"#
    let result = SummaryEngine.repairUnbalancedJSON(valid)
    #expect(result == valid)
}

@Test func repairUnbalancedJSONSwapsTrailingBracketMistake() {
    let broken = #"{"updates":[{"section":"X","bullets":["a","b"}]}"#
    let result = SummaryEngine.repairUnbalancedJSON(broken)
    #expect(result == #"{"updates":[{"section":"X","bullets":["a","b"]}]}"#)
}

@Test func repairUnbalancedJSONReturnsNilOnExtraClosers() {
    // Unsalvageable: more closing brackets than openers. Don't guess.
    let garbled = #"{"x":1}}}"#
    let result = SummaryEngine.repairUnbalancedJSON(garbled)
    #expect(result == nil)
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

@Test func consolidatePromptIncludesSummaryJSON() {
    let messages = SummaryPrompt.consolidate(
        summaryJSON: #"{"sections":[{"title":"X","bullets":["a","b"]}]}"#,
        language: "Japanese"
    )
    #expect(messages.count == 2)
    #expect(messages[0].role == .system)
    #expect(messages[1].content.contains(#"{"sections":[{"title":"X","bullets":["a","b"]}]}"#))
    #expect(messages[0].content.contains("Japanese"))
}

// MARK: - consolidate() runtime behaviour

/// Test double for `LLMClient`. Records the last request and returns a
/// canned response (or throws). Sendable via @unchecked because tests are
/// single-threaded — the actual atomicity guarantee comes from running
/// each test in isolation.
private final class CannedLLMClient: LLMClient, @unchecked Sendable {
    private(set) var requests: [[LLMMessage]] = []
    var response: String = "{}"
    var error: Error?

    func chat(model: String, messages: [LLMMessage], format: LLMResponseFormat, maxTokens: Int) async throws -> String {
        requests.append(messages)
        if let error { throw error }
        return response
    }
}

@Test func consolidateSkipsWhenSummaryHasFewerThanFourBullets() async throws {
    let client = CannedLLMClient()
    let engine = SummaryEngine(client: client, config: .init(model: "test"))
    // Seed via appendDelta — but rig the client to return a tiny summary.
    client.response = #"{"updates":[{"section":"A","bullets":["x","y","z"]}]}"#
    let now = Date()
    let segments = [TranscriptSegment(source: .microphone, text: "hi", startTime: now, endTime: now, isFinal: true)]
    _ = try await engine.appendDelta(newSegments: segments)
    // 3 bullets — below the threshold of 4. consolidate should be a no-op
    // (no extra LLM request beyond the appendDelta one).
    let beforeRequests = client.requests.count
    _ = try await engine.consolidate()
    #expect(client.requests.count == beforeRequests)
}

@Test func consolidateRunsAndAcceptsResultWhenAboveThreshold() async throws {
    let client = CannedLLMClient()
    let engine = SummaryEngine(client: client, config: .init(model: "test"))
    // Seed with 5 bullets so consolidate runs.
    client.response = #"{"updates":[{"section":"A","bullets":["a1","a2","a3","a4","a5"]}]}"#
    let now = Date()
    _ = try await engine.appendDelta(newSegments: [
        TranscriptSegment(source: .microphone, text: "seed", startTime: now, endTime: now, isFinal: true),
    ])
    // Now flip the canned response to the "consolidated" shape.
    client.response = #"{"sections":[{"title":"A","bullets":["a1","a2-a3 merged","a4","a5"]}]}"#
    let result = try await engine.consolidate()
    #expect(result.sections.count == 1)
    #expect(result.sections[0].bullets == ["a1", "a2-a3 merged", "a4", "a5"])
}

@Test func consolidateDiscardsResultWhenLLMShrinksTooMuch() async throws {
    let client = CannedLLMClient()
    let engine = SummaryEngine(client: client, config: .init(model: "test"))
    // Seed with 6 bullets.
    client.response = #"{"updates":[{"section":"X","bullets":["b1","b2","b3","b4","b5","b6"]}]}"#
    let now = Date()
    _ = try await engine.appendDelta(newSegments: [
        TranscriptSegment(source: .microphone, text: "seed", startTime: now, endTime: now, isFinal: true),
    ])
    let beforeBullets = await engine.currentSummary().sections.reduce(0) { $0 + $1.bullets.count }
    #expect(beforeBullets == 6)
    // Rig the consolidate response to drop too many bullets — 6 → 2 is
    // less than half retained, which trips the safety guard.
    client.response = #"{"sections":[{"title":"X","bullets":["super short tldr","another"]}]}"#
    let result = try await engine.consolidate()
    // Pre-consolidate state preserved.
    let afterBullets = result.sections.reduce(0) { $0 + $1.bullets.count }
    #expect(afterBullets == 6)
}

@Test func consolidatePromptCarriesCurrentSummaryToLLM() async throws {
    let client = CannedLLMClient()
    let engine = SummaryEngine(client: client, config: .init(model: "test", language: "Japanese"))
    client.response = #"{"updates":[{"section":"プロジェクトX","bullets":["bullet1","bullet2","bullet3","bullet4"]}]}"#
    let now = Date()
    _ = try await engine.appendDelta(newSegments: [
        TranscriptSegment(source: .microphone, text: "seed", startTime: now, endTime: now, isFinal: true),
    ])
    // Return same shape so the guard doesn't trip.
    client.response = #"{"sections":[{"title":"プロジェクトX","bullets":["bullet1","bullet2","bullet3","bullet4"]}]}"#
    _ = try await engine.consolidate()
    // The last LLM request should be the consolidate one — user message
    // carries the existing summary as JSON.
    let userPrompt = client.requests.last?.last?.content ?? ""
    #expect(userPrompt.contains("プロジェクトX"))
    #expect(userPrompt.contains("bullet1"))
}
