import Testing
import Foundation
@testable import GijirokuCore

@Test func extractsPlainJSONUnchanged() throws {
    let input = "{\"sections\":[{\"title\":\"A\",\"bullets\":[\"x\"]}]}"
    let json = try SummaryEngine.extractJSONPayload(input)
    let summary = try SummaryEngine.parse(response: json)
    #expect(summary.sections.first?.title == "A")
}

@Test func extractsJSONWithProsePreamble() throws {
    let input = """
    Sure! Here is the updated summary based on the transcript:

    {"sections":[{"title":"Roadmap","bullets":["Q3 hire","Q4 ship"]}]}

    Let me know if you'd like me to adjust anything.
    """
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.count == 1)
    #expect(summary.sections[0].title == "Roadmap")
    #expect(summary.sections[0].bullets == ["Q3 hire", "Q4 ship"])
}

@Test func extractsJSONWithMarkdownFenceAndProse() throws {
    let input = """
    Updated summary:

    ```json
    {"sections":[{"title":"Budget","bullets":["Cut 10%"]}]}
    ```

    Tell me what to change.
    """
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.first?.title == "Budget")
}

@Test func toleratesBracesInsideStringValues() throws {
    // Closing brace inside a string should not terminate the object early.
    let input = "Result: {\"sections\":[{\"title\":\"X}Y\",\"bullets\":[\"a\"]}]} done"
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.first?.title == "X}Y")
}

@Test func toleratesEscapedQuotesInStrings() throws {
    let input = "{\"sections\":[{\"title\":\"He said \\\"hi\\\"\",\"bullets\":[\"a\"]}]}"
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.first?.title == "He said \"hi\"")
}

@Test func throwsWhenNoJSONObjectFound() {
    let input = "Sorry, I cannot summarize this."
    #expect {
        try SummaryEngine.extractJSONPayload(input)
    } throws: { error in
        guard case .noJSONObject(let snippet) = error as? LLMParseError else { return false }
        // The snippet should carry the raw response so the user/log can see
        // what the model returned.
        return snippet.contains("Sorry")
    }
}

@Test func parseFailsWithEmptyResponseError() {
    #expect {
        try SummaryEngine.parse(response: "   \n  ")
    } throws: { error in
        return (error as? LLMParseError) == .emptyResponse
    }
}

@Test func parseGracefullyReturnsEmptyOnUnrecognizedSchema() throws {
    // Valid JSON but no fields the coercer recognizes. New behaviour: don't
    // throw — return an empty summary so the recording loop keeps running
    // and the next batch gets a chance. The previous strict-decode
    // behaviour surfaced an error to the user for every off-schema turn.
    let input = "{\"unrelated\": 42}"
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.isEmpty)
}

@Test func eventExtractorAcceptsEmptyArray() throws {
    let events = try EventExtractor.parse(response: "[]")
    #expect(events.isEmpty)
}

@Test func eventExtractorAcceptsEmptyArrayWithFencesAndPadding() throws {
    let events1 = try EventExtractor.parse(response: "   []   ")
    #expect(events1.isEmpty)
    let events2 = try EventExtractor.parse(response: "```json\n[]\n```")
    #expect(events2.isEmpty)
    let events3 = try EventExtractor.parse(response: "<think>nothing to extract</think>\n[]")
    #expect(events3.isEmpty)
}

@Test func eventExtractorAcceptsEmptyEnvelopeArray() throws {
    let events = try EventExtractor.parse(response: #"{"events":[]}"#)
    #expect(events.isEmpty)
}

@Test func eventExtractorAcceptsBareSingleEvent() throws {
    // The LLM emitted a single event object instead of the canonical
    // {"events":[...]} envelope — this used to fail with LLMParseError.
    let input = #"{"kind":"question","text":"why?","owner":null,"due":null}"#
    let events = try EventExtractor.parse(response: input)
    #expect(events.count == 1)
    #expect(events[0].kind == .question)
    #expect(events[0].text == "why?")
}

@Test func eventExtractorAcceptsTopLevelArray() throws {
    let input = """
    [
      {"kind":"decision","text":"go with plan A"},
      {"kind":"action","text":"draft proposal","owner":"alice"}
    ]
    """
    let events = try EventExtractor.parse(response: input)
    #expect(events.count == 2)
    #expect(events[0].kind == .decision)
    #expect(events[1].owner == "alice")
}

@Test func summaryEngineAcceptsBareSingleSection() throws {
    let input = #"{"title":"Intro","bullets":["one","two"]}"#
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.count == 1)
    #expect(summary.sections[0].title == "Intro")
    #expect(summary.sections[0].bullets == ["one", "two"])
}

@Test func summaryEngineSalvagesBulletsAsNumberedObjects() throws {
    // Real-world failure from a small model: bullets came back as an array
    // of single-key {"1":"…"},{"2":"…"} objects instead of plain strings.
    // The coercer flattens those into the bullet list, sorting the numeric
    // keys to preserve order.
    let input = """
    {"sections":[{"title":"情報セキュリティの難しさ","bullets":[
      {"1":"システムが大きすぎてミスなしは無理"},
      {"2":"OSの内部の複雑さが問題"},
      {"10":"最後の項目"}
    ]}]}
    """
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.count == 1)
    let bullets = summary.sections[0].bullets
    #expect(bullets.count == 3)
    #expect(bullets[0] == "システムが大きすぎてミスなしは無理")
    #expect(bullets[1] == "OSの内部の複雑さが問題")
    // Numeric keys sort by integer value, so "10" comes after "2".
    #expect(bullets[2] == "最後の項目")
}

@Test func summaryEngineAcceptsAlternativeKeyNames() throws {
    // "heading" instead of "title", "points" instead of "bullets" — keep
    // working as long as the structure is recognizable.
    let input = #"{"sections":[{"heading":"X","points":["a","b"]}]}"#
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.count == 1)
    #expect(summary.sections[0].title == "X")
    #expect(summary.sections[0].bullets == ["a", "b"])
}

@Test func summaryEngineHandlesMixedBulletShapes() throws {
    // Bullets can be a mix of strings, numbers, and nested objects — all
    // get flattened to a single string list.
    let input = #"{"sections":[{"title":"X","bullets":["a", 42, {"key":"b"}, ["nested","c"]]}]}"#
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections[0].bullets == ["a", "42", "b", "nested", "c"])
}

@Test func eventExtractorAcceptsAlternativeKindAndOwnerKeys() throws {
    let input = #"[{"type":"action","content":"do thing","assignee":"alice","deadline":"Fri"}]"#
    let events = try EventExtractor.parse(response: input)
    #expect(events.count == 1)
    #expect(events[0].kind == .action)
    #expect(events[0].text == "do thing")
    #expect(events[0].owner == "alice")
    #expect(events[0].dueDate == "Fri")
}

@Test func eventExtractorReadsResolvedFlag() throws {
    let input = #"""
    {"events":[
      {"kind":"question","text":"いつまで?","resolved":true},
      {"kind":"action","text":"do thing"}
    ]}
    """#
    let events = try EventExtractor.parse(response: input)
    #expect(events.count == 2)
    #expect(events[0].resolved == true)
    #expect(events[1].resolved == false)
}

@Test func meetingEventDecodesLegacyJSONWithoutResolvedField() throws {
    // Older session files don't have a `resolved` key. Decoder must default
    // to false so the file loads cleanly.
    let legacy = """
    {"id":"00000000-0000-0000-0000-000000000001","kind":"question","text":"why?","detectedAt":"2026-01-01T00:00:00Z"}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let event = try decoder.decode(MeetingEvent.self, from: legacy)
    #expect(event.resolved == false)
    #expect(event.text == "why?")
}

@Test func summaryEngineAcceptsTopLevelArray() throws {
    let input = """
    [
      {"title":"A","bullets":["a1"]},
      {"title":"B","bullets":["b1","b2"]}
    ]
    """
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.count == 2)
    #expect(summary.sections[1].bullets.count == 2)
}

@Test func eventExtractorAlsoStripsProse() throws {
    let input = """
    Sure, here are the events I found:
    {"events":[{"kind":"action","text":"Update docs","owner":"alice","due":"Friday"}]}
    Hope that helps.
    """
    let events = try EventExtractor.parse(response: input)
    #expect(events.count == 1)
    #expect(events[0].owner == "alice")
    #expect(events[0].dueDate == "Friday")
}

@Test func extractsFirstObjectWhenMultiplePresent() throws {
    // If the LLM hallucinates multiple objects, we take the first balanced one.
    let input = "{\"sections\":[{\"title\":\"A\",\"bullets\":[]}]} extra {\"foo\":\"bar\"}"
    let summary = try SummaryEngine.parse(response: input)
    #expect(summary.sections.first?.title == "A")
}
