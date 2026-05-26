import Testing
import Foundation
@testable import GijirokuCore

private func segment(_ text: String, source: AudioSource = .microphone, start: TimeInterval = 0, duration: TimeInterval = 1, id: UUID = UUID()) -> TranscriptSegment {
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    return TranscriptSegment(
        id: id,
        source: source,
        text: text,
        startTime: origin.addingTimeInterval(start),
        endTime: origin.addingTimeInterval(start + duration),
        isFinal: false
    )
}

@Test func appendsFirstSegment() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    let outcome = dedup.merge(segment("今日の会議"), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 1)
}

@Test func keepsExactDuplicateAsSingleEntry() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("今日の会議は重要です"), into: &list)
    let outcome = dedup.merge(segment("今日の会議は重要です"), into: &list)
    #expect(outcome == .ignored || outcome == .replaced(previousID: list[0].id))
    #expect(list.count == 1)
}

@Test func mergesLongerTailIntoExisting() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("検索機能とエクスポート機能のうち", start: 0, duration: 3), into: &list)
    let outcome = dedup.merge(
        segment("検索機能とエクスポート機能のうち、検索機能を先に実装する", start: 0.5, duration: 4),
        into: &list
    )
    #expect(list.count == 1)
    #expect(list[0].text == "検索機能とエクスポート機能のうち、検索機能を先に実装する")
    if case .replaced = outcome {} else { Issue.record("expected .replaced, got \(outcome)") }
}

@Test func differentSourcesAreNeverMerged() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("hello world", source: .microphone), into: &list)
    let outcome = dedup.merge(segment("hello world", source: .system), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 2)
}

@Test func unrelatedSegmentsBothKept() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("田中さんは来週金曜日までに更新してください"), into: &list)
    let outcome = dedup.merge(segment("予算については来週改めて議論することにします"), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 2)
}

@Test func dedupesAcrossSmallVariations() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("ご視聴ありがとうございました"), into: &list)
    let outcome = dedup.merge(segment("ご視聴ありがとうございました。"), into: &list)
    #expect(list.count == 1)
    if case .replaced = outcome {} else if outcome == .ignored {} else {
        Issue.record("expected .replaced or .ignored, got \(outcome)")
    }
}

@Test func windowLimitsLookback() {
    let dedup = TranscriptDeduper(config: .init(lookbackWindow: 2))
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("alpha beta gamma"), into: &list)
    _ = dedup.merge(segment("delta epsilon"), into: &list)
    _ = dedup.merge(segment("zeta eta theta"), into: &list)
    // "alpha beta gamma" は window 外なので、もう一度来ても上書きされず追加される
    let outcome = dedup.merge(segment("alpha beta gamma"), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 4)
}

@Test func similarityZeroForCompletelyDifferent() {
    #expect(TranscriptDeduper.similarity("abcdef", "xyz123") < 0.3)
}

@Test func containedTextButTimeFarApartIsNotMerged() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("今日", start: 0), into: &list)
    let outcome = dedup.merge(segment("今日は雨だ", start: 60), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 2)
}
