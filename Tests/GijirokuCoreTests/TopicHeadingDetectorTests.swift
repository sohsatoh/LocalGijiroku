import Testing
import Foundation
@testable import GijirokuCore

@Test func parsesChangedHeadingDecision() throws {
    let response = #"""
    {"changed":true,"heading":"価格戦略"}
    """#
    let decision = try TopicHeadingDetector.parse(response: response, maxLen: 24)
    #expect(decision.changed == true)
    #expect(decision.heading == "価格戦略")
}

@Test func parsesUnchangedDecisionAsNilHeading() throws {
    let decision = try TopicHeadingDetector.parse(
        response: "{\"changed\":false,\"heading\":null}",
        maxLen: 24
    )
    #expect(decision.changed == false)
    #expect(decision.heading == nil)
}

@Test func parserNormalizesChangedTrueWithBlankHeadingToUnchanged() throws {
    // Some small models stamp `changed:true` but emit an empty heading.
    // Inserting a blank divider in the transcript would be worse than
    // leaving the previous heading in place.
    let decision = try TopicHeadingDetector.parse(
        response: "{\"changed\":true,\"heading\":\"\"}",
        maxLen: 24
    )
    #expect(decision.changed == false)
    #expect(decision.heading == nil)
}

@Test func parserAcceptsAliasFields() throws {
    let decision = try TopicHeadingDetector.parse(
        response: "{\"topic_changed\":true,\"title\":\"新しい話題\"}",
        maxLen: 24
    )
    #expect(decision.changed == true)
    #expect(decision.heading == "新しい話題")
}

@Test func sanitizeStripsPrefixesAndCapsLength() {
    let result = TopicHeadingDetector.sanitize("Heading: 「とても長い見出しの例」", maxLen: 8)
    #expect(result == "とても長い見出し")
}

@Test func sanitizeRemovesEnclosingQuotes() {
    let result = TopicHeadingDetector.sanitize("\"価格戦略\"", maxLen: 24)
    #expect(result == "価格戦略")
}

@Test func detectPromptSurfacesPreviousHeadingAndTranscript() {
    let messages = HeadingPrompt.detect(
        previous: "市場分析",
        transcript: "[A] では価格戦略に移ります",
        language: "ja",
        maxLen: 24
    )
    let user = messages.last?.content ?? ""
    #expect(user.contains("Current heading: 市場分析"))
    #expect(user.contains("[A] では価格戦略に移ります"))
    let system = messages.first?.content ?? ""
    #expect(system.contains("Always answer in Japanese"))
    #expect(system.contains("≤ 24"))
}

@Test func detectPromptHandlesAbsentPreviousHeading() {
    let messages = HeadingPrompt.detect(
        previous: nil,
        transcript: "[A] こんにちは",
        language: "auto",
        maxLen: 16
    )
    let user = messages.last?.content ?? ""
    #expect(user.contains("(none yet"))
}
