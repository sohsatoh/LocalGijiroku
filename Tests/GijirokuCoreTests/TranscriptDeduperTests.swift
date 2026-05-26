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

@Test func differentSourcesAreKeptWhenBleedSuppressionDisabled() {
    let dedup = TranscriptDeduper(config: .init(crossSourceBleedSuppression: false))
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("hello world", source: .microphone), into: &list)
    let outcome = dedup.merge(segment("hello world", source: .system), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 2)
}

@Test func micBleedIsDroppedWhenSystemAlreadyHasIt() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("今日の議題はリリース計画です", source: .system, start: 0), into: &list)
    // Microphone picked up the same audio bleeding through the speaker, a
    // beat later — should be suppressed.
    let outcome = dedup.merge(segment("今日の議題はリリース計画です", source: .microphone, start: 0.4), into: &list)
    #expect(outcome == .ignored)
    #expect(list.count == 1)
    #expect(list[0].source == .system)
}

@Test func systemAudioUpgradesPriorMicBleed() {
    // Edge case: mic transcribed the bleed first (mic stream had less buffer
    // lag this round), then the cleaner system version arrives. The mic
    // entry should be replaced with the system version, preserving its UUID
    // so AppModel's pending-for-summary buffer stays in sync.
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    let micID = UUID()
    _ = dedup.merge(segment("プロジェクトを来週ローンチします", source: .microphone, start: 0, id: micID), into: &list)
    let outcome = dedup.merge(segment("プロジェクトを来週ローンチします", source: .system, start: 0.2), into: &list)
    if case .replaced(let previousID) = outcome {
        #expect(previousID == micID)
    } else {
        Issue.record("expected .replaced, got \(outcome)")
    }
    #expect(list.count == 1)
    #expect(list[0].id == micID)
    #expect(list[0].source == .system)
}

@Test func crossSourceMatchRequiresTimeProximity() {
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("hello world", source: .system, start: 0), into: &list)
    // Mic says the same words 30s later — completely unrelated to the
    // earlier system audio, must NOT be suppressed.
    let outcome = dedup.merge(segment("hello world", source: .microphone, start: 30), into: &list)
    #expect(outcome == .appended)
    #expect(list.count == 2)
}

@Test func crossSourceDoesNotSuppressUnrelatedMicText() {
    // The user is speaking their own thing while system audio is playing
    // something else. Different text → both kept.
    let dedup = TranscriptDeduper()
    var list: [TranscriptSegment] = []
    _ = dedup.merge(segment("メールの返信を後で送ります", source: .system, start: 0), into: &list)
    let outcome = dedup.merge(segment("私の意見ではこれは進めるべきです", source: .microphone, start: 0.3), into: &list)
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
