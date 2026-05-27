import Testing
import Foundation
@testable import GijirokuCore

@Test func parsesAgendaSuggestionEnvelope() throws {
    let json = #"""
    {"suggestions":[
      {"text":"オンボーディング方針"},
      {"text":"サポート体制の合意"}
    ]}
    """#
    let events = try AgendaSuggester.parse(response: json)
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.kind == .agendaSuggestion })
    #expect(events.map(\.text) == ["オンボーディング方針", "サポート体制の合意"])
}

@Test func parsesEmptySuggestionsArray() throws {
    let events = try AgendaSuggester.parse(response: "{\"suggestions\":[]}")
    #expect(events.isEmpty)
}

@Test func parsesResolvedAgendaSuggestionWithOutcome() throws {
    let json = #"""
    {"suggestions":[
      {"text":"オンボーディング方針","resolved":true,"resolution":"次回までに田中がドラフト"}
    ]}
    """#
    let events = try AgendaSuggester.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].resolved == true)
    #expect(events[0].resolution == "次回までに田中がドラフト")
}

@Test func parserDropsBlankTextEntries() throws {
    let json = #"""
    {"suggestions":[{"text":""},{"text":"  "},{"text":"有効な提案"}]}
    """#
    let events = try AgendaSuggester.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].text == "有効な提案")
}

@Test func parserAcceptsAliasKeysAndEnvelopes() throws {
    // Small models love to drift toward "topics" / "items" envelopes or
    // emit "topic"/"title" for the text field. The coercer is what lets
    // us keep prompt-only MLX backends working without strict schema.
    let json = #"""
    {"topics":[{"topic":"請求フロー","outcome":"次回に持ち越し","closed":true}]}
    """#
    let events = try AgendaSuggester.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].text == "請求フロー")
    #expect(events[0].resolved == true)
    #expect(events[0].resolution == "次回に持ち越し")
}

@Test func promptIncludesSummaryOpenAndRecentSlices() {
    let summary = CumulativeSummary(sections: [
        .init(title: "Pricing", bullets: ["Discount tier proposed at 10%"]),
    ])
    let openSuggestions = [
        MeetingEvent(kind: .agendaSuggestion, text: "サポート体制の合意"),
    ]
    let recordedEvents = [
        MeetingEvent(kind: .action, text: "提案書を金曜までに送る", owner: "田中"),
    ]
    let messages = AgendaPrompt.suggest(
        summary: summary,
        openSuggestions: openSuggestions,
        recordedEvents: recordedEvents,
        recentTranscript: "[A] 価格について検討中",
        maxSuggestions: 2
    )
    let user = messages.last?.content ?? ""
    #expect(user.contains("Running summary"))
    #expect(user.contains("### Pricing"))
    #expect(user.contains("Discount tier proposed at 10%"))
    #expect(user.contains("OPEN suggestions"))
    #expect(user.contains("サポート体制の合意"))
    #expect(user.contains("already captured by the extractor"))
    #expect(user.contains("[action] 提案書を金曜までに送る"))
    #expect(user.contains("Recent transcript slice"))
    #expect(user.contains("[A] 価格について検討中"))
}

@Test func renderOpenSuggestionsSkipsResolvedAndNonSuggestionKinds() {
    let events = [
        MeetingEvent(kind: .agendaSuggestion, text: "未討議の論点"),
        MeetingEvent(kind: .agendaSuggestion, text: "既決の提案", resolved: true),
        MeetingEvent(kind: .question, text: "余計に混ざる質問"),
    ]
    let rendered = AgendaPrompt.renderOpenSuggestions(events)
    #expect(rendered.contains("未討議の論点"))
    #expect(!rendered.contains("既決の提案"))
    #expect(!rendered.contains("余計に混ざる質問"))
}

@Test func renderRecordedEventsExcludesAgendaSuggestions() {
    let events = [
        MeetingEvent(kind: .action, text: "提案書を送る"),
        MeetingEvent(kind: .agendaSuggestion, text: "未討議"),
    ]
    let rendered = AgendaPrompt.renderRecordedEvents(events)
    #expect(rendered.contains("[action] 提案書を送る"))
    #expect(!rendered.contains("未討議"))
}
