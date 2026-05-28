import Testing
import Foundation
@testable import GijirokuCore

@Test func parsesAllEventKinds() throws {
    let json = """
    {"events":[
      {"kind":"action","text":"Update docs","owner":"alice","due":"Friday"},
      {"kind":"question","text":"Which DB do we use?"},
      {"kind":"decision","text":"Adopt Postgres"}
    ]}
    """
    let events = try EventExtractor.parse(response: json)
    #expect(events.count == 3)
    #expect(events[0].kind == .action)
    #expect(events[0].owner == "alice")
    #expect(events[0].dueDate == "Friday")
    #expect(events[1].kind == .question)
    #expect(events[1].owner == nil)
    #expect(events[2].kind == .decision)
}

@Test func parsesEmptyEventsArray() throws {
    let events = try EventExtractor.parse(response: "{\"events\":[]}")
    #expect(events.isEmpty)
}

@Test func dropsUnknownKind() throws {
    let json = """
    {"events":[{"kind":"banter","text":"hello"},{"kind":"action","text":"do thing"}]}
    """
    let events = try EventExtractor.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].kind == .action)
}

@Test func normalizesEmptyOwnerToNil() throws {
    let json = """
    {"events":[{"kind":"action","text":"X","owner":"","due":""}]}
    """
    let events = try EventExtractor.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].owner == nil)
    #expect(events[0].dueDate == nil)
}

@Test func tolerantToUppercaseKind() throws {
    let events = try EventExtractor.parse(response: "{\"events\":[{\"kind\":\"ACTION\",\"text\":\"X\"}]}")
    #expect(events.count == 1)
    #expect(events[0].kind == .action)
}

@Test func renderOpenEventsIsEmptyWhenNoneOrAllResolved() {
    #expect(EventPrompt.renderOpenEvents([]).isEmpty)
    let allResolved = [
        MeetingEvent(kind: .question, text: "X", resolved: true),
        MeetingEvent(kind: .action, text: "Y", resolved: true),
    ]
    #expect(EventPrompt.renderOpenEvents(allResolved).isEmpty)
}

@Test func renderOpenEventsListsOnlyUnresolvedWithMeta() {
    let events = [
        MeetingEvent(kind: .question, text: "競合分析の期限"),
        MeetingEvent(kind: .action, text: "提案書をまとめる", owner: "田中", dueDate: "金曜"),
        MeetingEvent(kind: .agendaSuggestion, text: "オンボーディング方針", resolved: true),
    ]
    let rendered = EventPrompt.renderOpenEvents(events)
    #expect(rendered.contains("[question] 競合分析の期限"))
    #expect(rendered.contains("[action] 提案書をまとめる (owner: 田中, due: 金曜)"))
    // Resolved entries are filtered out — they're not the LLM's concern.
    #expect(!rendered.contains("オンボーディング方針"))
}

@Test func extractPromptOmitsOpenItemsBlockWhenEmpty() {
    let messages = EventPrompt.extract(transcript: "[A] hello", openEvents: [])
    let userPrompt = messages.last?.content ?? ""
    // Bare transcript, no "OPEN items" header.
    #expect(userPrompt == "[A] hello")
}

@Test func extractPromptIncludesOpenItemsBlockWhenPresent() {
    let open = [MeetingEvent(kind: .question, text: "競合分析の期限")]
    let messages = EventPrompt.extract(transcript: "[A] 金曜まで", openEvents: open)
    let userPrompt = messages.last?.content ?? ""
    #expect(userPrompt.contains("## OPEN items"))
    #expect(userPrompt.contains("[question] 競合分析の期限"))
    #expect(userPrompt.contains("## New transcript fragment"))
    #expect(userPrompt.contains("[A] 金曜まで"))
}

@Test func resolutionFlowsThroughMergerWhenLLMReEmitsResolved() throws {
    // Simulate the round trip: turn N extracts an open question; turn N+1
    // sees an answer and the LLM re-emits the same question with
    // resolved=true + resolution. The merger should fold the resolution
    // into the existing entry (same id, resolved upgraded).
    let originalID = UUID()
    var list = [
        MeetingEvent(
            id: originalID,
            kind: .question,
            text: "競合分析の期限"
        )
    ]
    let resolvedEcho = try EventExtractor.parse(response: #"""
    {"events":[{"kind":"question","text":"競合分析の期限","resolved":true,"resolution":"金曜まで"}]}
    """#)
    EventMerger().merge(resolvedEcho, into: &list)
    #expect(list.count == 1)
    #expect(list[0].id == originalID)
    #expect(list[0].resolved == true)
    #expect(list[0].resolution == "金曜まで")
}

// Sessions saved before the rename used kind="topic"; that bucket is now
// .agendaSuggestion. Both the live LLM-response path and the on-disk
// Codable decoder need to honor the alias, otherwise old sessions either
// drop their proposed-topic events or fail to deserialize entirely.
@Test func parseTreatsLegacyTopicKindAsAgendaSuggestion() throws {
    let events = try EventExtractor.parse(response: #"""
    {"events":[{"kind":"topic","text":"オンボーディング方針"}]}
    """#)
    #expect(events.count == 1)
    #expect(events[0].kind == .agendaSuggestion)
}

@Test func meetingEventDecoderAcceptsLegacyTopicRawValue() throws {
    let originalID = UUID()
    let json = #"""
    {
      "id": "\#(originalID.uuidString)",
      "kind": "topic",
      "text": "話題例",
      "detectedAt": 0
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let event = try decoder.decode(MeetingEvent.self, from: Data(json.utf8))
    #expect(event.id == originalID)
    #expect(event.kind == .agendaSuggestion)
    #expect(event.text == "話題例")
}

@Test func meetingEventDecoderAcceptsAgendaSuggestionRawValue() throws {
    let originalID = UUID()
    let json = #"""
    {
      "id": "\#(originalID.uuidString)",
      "kind": "agendaSuggestion",
      "text": "未討議の論点",
      "detectedAt": 0
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let event = try decoder.decode(MeetingEvent.self, from: Data(json.utf8))
    #expect(event.id == originalID)
    #expect(event.kind == .agendaSuggestion)
    #expect(event.text == "未討議の論点")
}

@Test func renderOpenEventsHidesAgendaSuggestionsFromExtractorPrompt() {
    let events = [
        MeetingEvent(kind: .question, text: "競合分析の期限"),
        MeetingEvent(kind: .agendaSuggestion, text: "オンボーディング方針"),
    ]
    let rendered = EventPrompt.renderOpenEvents(events)
    #expect(rendered.contains("競合分析の期限"))
    // Agenda suggestions belong to AgendaSuggester's prompt, not the
    // extractor's — they must not leak into the OPEN items block.
    #expect(!rendered.contains("オンボーディング方針"))
}
