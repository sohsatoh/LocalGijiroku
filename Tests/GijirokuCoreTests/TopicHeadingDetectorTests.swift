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

// Smallest possible LLMClient stub: returns a canned response on the
// first chat call. Plenty for actor unit tests that need to observe
// what the actor *did* with whatever it got back.
private actor StubLLMClient: LLMClient {
    let canned: String
    var callCount = 0
    init(_ canned: String = "{\"changed\":false,\"heading\":null}") {
        self.canned = canned
    }
    func chat(model: String, messages: [LLMMessage], format: LLMResponseFormat, maxTokens: Int) async throws -> String {
        callCount += 1
        return canned
    }
}

@Test func detectorSkipsLLMCallWhenWindowTooSmallWithExistingHeading() async throws {
    // With a previous heading, the bar to overwrite it is high — a
    // 2-line tangent shouldn't trigger a new section. We assert the
    // early return BEFORE the LLM gets called by inspecting the
    // stub's call count.
    let stub = StubLLMClient("{\"changed\":true,\"heading\":\"NOPE\"}")
    let detector = TopicHeadingDetector(client: stub)
    let now = Date()
    let segments = [
        TranscriptSegment(source: .microphone, text: "side note", startTime: now, endTime: now.addingTimeInterval(2), isFinal: true),
        TranscriptSegment(source: .microphone, text: "and another", startTime: now.addingTimeInterval(3), endTime: now.addingTimeInterval(5), isFinal: true),
    ]
    let previous = TranscriptHeading(text: "Pricing", startTime: now.addingTimeInterval(-120))
    let decision = try await detector.detect(previousHeading: previous, recentSegments: segments)
    #expect(decision.changed == false)
    #expect(decision.heading == nil)
    let calls = await stub.callCount
    #expect(calls == 0)
}

@Test func detectorAllowsLLMCallOnFirstDetectionWithTwoLines() async throws {
    // The very first heading is allowed at the lower 2-line bar so
    // that meetings get a heading once they actually start. With no
    // previous heading the detector must reach the LLM.
    let stub = StubLLMClient("{\"changed\":true,\"heading\":\"会議開始\"}")
    let detector = TopicHeadingDetector(client: stub)
    let now = Date()
    let segments = [
        TranscriptSegment(source: .microphone, text: "始めます", startTime: now, endTime: now.addingTimeInterval(2), isFinal: true),
        TranscriptSegment(source: .microphone, text: "アジェンダから", startTime: now.addingTimeInterval(3), endTime: now.addingTimeInterval(5), isFinal: true),
    ]
    let decision = try await detector.detect(previousHeading: nil, recentSegments: segments)
    #expect(decision.changed == true)
    #expect(decision.heading == "会議開始")
    let calls = await stub.callCount
    #expect(calls == 1)
}
