import Testing
import Foundation
@testable import GijirokuCore

private func event(_ text: String, kind: MeetingEvent.Kind = .action, owner: String? = nil, due: String? = nil, id: UUID = UUID()) -> MeetingEvent {
    MeetingEvent(id: id, kind: kind, text: text, owner: owner, dueDate: due)
}

@Test func appendsBrandNewEvent() {
    let merger = EventMerger()
    var list: [MeetingEvent] = []
    merger.merge([event("Send the report", kind: .action)], into: &list)
    #expect(list.count == 1)
}

@Test func mergesDuplicateActionKeepingOriginalID() {
    let merger = EventMerger()
    let first = event("Update docs", kind: .action, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    var list = [first]
    merger.merge([event("Update docs", kind: .action)], into: &list)
    #expect(list.count == 1)
    #expect(list[0].id == first.id)
}

@Test func upgradesOwnerAndDueOnSecondPass() {
    let merger = EventMerger()
    var list = [event("Update docs by Friday", kind: .action)]
    merger.merge([
        event("Update docs by Friday", kind: .action, owner: "alice", due: "Friday"),
    ], into: &list)
    #expect(list.count == 1)
    #expect(list[0].owner == "alice")
    #expect(list[0].dueDate == "Friday")
}

@Test func differentKindIsNotDeduped() {
    let merger = EventMerger()
    var list = [event("Adopt Postgres", kind: .decision)]
    merger.merge([event("Adopt Postgres", kind: .action)], into: &list)
    #expect(list.count == 2)
}

@Test func wordingShiftWithinPrefixIsDeduped() {
    let merger = EventMerger()
    var list = [event("検索機能とエクスポート機能のうち、検索機能を先に実装する", kind: .decision)]
    merger.merge([
        event("検索機能とエクスポート機能のうち、検索機能を先に実装することに決めました", kind: .decision),
    ], into: &list)
    #expect(list.count == 1)
    // longer text wins
    #expect(list[0].text.contains("することに決めました"))
}

@Test func nearDuplicateWithOneCharDriftIsDeduped() {
    // The real failure mode the user reported: Whisper transcribed the
    // same question two different ways across cycles ("リテラシー" vs
    // "リテラー"). The old prefix-key dedup missed this because the keys
    // diverged at char 6; the new directional bigram check keeps them
    // merged.
    let merger = EventMerger()
    var list = [event("個人のリテラシーとしてどこまで自分で理解すべきか", kind: .question)]
    merger.merge([
        event("個人のリテラーとしてどこまで自分で理解すべきか", kind: .question),
    ], into: &list)
    #expect(list.count == 1)
}

@Test func unrelatedEventsBothKept() {
    // Two genuinely different action items must stay separate even when
    // they share a leading verb. The similarity check sits below the
    // threshold for these.
    let merger = EventMerger()
    var list = [event("Send the quarterly report to the executive team")]
    merger.merge([event("Send the design draft to the marketing team")], into: &list)
    #expect(list.count == 2)
}

@Test func normalizationCollapsesWhitespaceAndCase() {
    let merger = EventMerger()
    var list = [event("Update Docs")]
    merger.merge([event("update　docs")], into: &list)
    #expect(list.count == 1)
}
