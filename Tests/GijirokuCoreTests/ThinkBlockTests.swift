import Testing
import Foundation
@testable import GijirokuCore

@Test func stripsBasicThinkBlock() {
    let input = "<think>let me consider</think>{\"sections\":[]}"
    let output = SummaryEngine.stripThinkBlocks(input)
    #expect(output == "{\"sections\":[]}")
}

@Test func stripsMultilineThinkBlock() {
    let input = """
    <think>
    The user wants me to summarize.
    I should focus on decisions.
    </think>
    {"sections":[{"title":"X","bullets":["a"]}]}
    """
    let output = SummaryEngine.stripThinkBlocks(input)
    #expect(output == "{\"sections\":[{\"title\":\"X\",\"bullets\":[\"a\"]}]}")
}

@Test func stripsMultipleThinkBlocks() {
    let input = "<think>step1</think>foo<think>step2</think>bar"
    let output = SummaryEngine.stripThinkBlocks(input)
    #expect(output == "foobar")
}

@Test func stripsUnclosedThinkTag() {
    let input = "{\"valid\":true}<think>oh wait let me reconsider..."
    let output = SummaryEngine.stripThinkBlocks(input)
    #expect(output == "{\"valid\":true}")
}

@Test func parsesJSONAfterThinkBlock() throws {
    let raw = """
    <think>
    The user wants a meeting summary.
    Let me extract two sections.
    </think>
    Sure, here it is:
    {"sections":[{"title":"Plan","bullets":["Q3 hire"]}]}
    """
    let summary = try SummaryEngine.parse(response: raw)
    #expect(summary.sections.count == 1)
    #expect(summary.sections[0].title == "Plan")
}

@Test func eventExtractorParsesAfterThinkBlock() throws {
    let raw = """
    <think>looking for action items...</think>
    {"events":[{"kind":"action","text":"Do thing","owner":"alice"}]}
    """
    let events = try EventExtractor.parse(response: raw)
    #expect(events.count == 1)
    #expect(events[0].owner == "alice")
}
