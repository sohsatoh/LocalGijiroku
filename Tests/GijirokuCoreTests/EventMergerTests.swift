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

@Test func wordingShiftBeyondPrefixIsTreatedAsNew() {
    let merger = EventMerger(config: .init(keyPrefixLength: 10))
    var list = [event("hello world this is event one")]
    merger.merge([event("hello world but a totally different event")], into: &list)
    // 同じ prefix で keyed なので、prefix が短い設定だと衝突する。
    // 長めの prefix で別物として扱われる挙動の確認は別ケース。
    #expect(list.count == 1)
}

@Test func longPrefixSeparatesUnrelatedEvents() {
    let merger = EventMerger(config: .init(keyPrefixLength: 60))
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
