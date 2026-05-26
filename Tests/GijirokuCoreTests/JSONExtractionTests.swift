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
    #expect(throws: LLMParseError.noJSONObject) {
        try SummaryEngine.extractJSONPayload(input)
    }
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
