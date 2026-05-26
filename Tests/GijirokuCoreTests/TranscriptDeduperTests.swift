import Testing
import Foundation
@testable import GijirokuCore

// MARK: - Confirmation streaming

@Test func confirmationStaysStickyAgainstUnconfirmedRewrite() {
    // Whisper re-emits the same time range in a later cycle (rolling
    // window). The first emission was confirmed; the refinement arrives
    // unconfirmed with slightly different wording. The confirmed text
    // wins — once we've trusted it, we don't let an unstable rewrite
    // overwrite it.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let confirmed = TranscriptSegment(
        source: .microphone,
        text: "今日はいい天気です",
        startTime: now,
        endTime: now.addingTimeInterval(3),
        isFinal: true,
        isConfirmed: true
    )
    var transcript = [confirmed]
    let refinement = TranscriptSegment(
        source: .microphone,
        text: "今日はいい天気ですね今",
        startTime: now,
        endTime: now.addingTimeInterval(3.5),
        isFinal: false,
        isConfirmed: false
    )
    _ = deduper.merge(refinement, into: &transcript)
    #expect(transcript.count == 1)
    #expect(transcript[0].text == "今日はいい天気です")
    #expect(transcript[0].isConfirmed == true)
}

@Test func unconfirmedSegmentPromotedByLaterConfirmedEcho() {
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let unconf = TranscriptSegment(
        source: .system,
        text: "プランBで行きます",
        startTime: now,
        endTime: now.addingTimeInterval(2),
        isFinal: false,
        isConfirmed: false
    )
    var transcript = [unconf]
    let later = TranscriptSegment(
        source: .system,
        text: "プランBで行きます",
        startTime: now,
        endTime: now.addingTimeInterval(2),
        isFinal: true,
        isConfirmed: true
    )
    let outcome = deduper.merge(later, into: &transcript)
    #expect(outcome == .replaced(previousID: unconf.id))
    #expect(transcript.count == 1)
    #expect(transcript[0].isConfirmed == true)
}

// MARK: - Cross-cycle re-segmentation

@Test func collapsesEarlierFragmentWhenLaterCycleEmitsCombinedSentence() {
    // Cycle 1 emitted two separate confirmed segments for one utterance.
    // Cycle 2 re-decoded the same rolling audio and emitted a single
    // combined segment that contains both fragments. The deduper must
    // replace the most-recent match AND sweep the earlier fragment that
    // is now fully subsumed by the merged text — otherwise the UI shows
    // "今日は晴れです。" twice.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let a = TranscriptSegment(
        source: .microphone,
        text: "今日は晴れです。",
        startTime: now,
        endTime: now.addingTimeInterval(2),
        isFinal: true
    )
    let b = TranscriptSegment(
        source: .microphone,
        text: "明日は雨です。",
        startTime: now.addingTimeInterval(2),
        endTime: now.addingTimeInterval(4),
        isFinal: true
    )
    var transcript: [TranscriptSegment] = [a, b]
    let combined = TranscriptSegment(
        source: .microphone,
        text: "今日は晴れです。明日は雨です。",
        startTime: now,
        endTime: now.addingTimeInterval(4),
        isFinal: true
    )
    _ = deduper.merge(combined, into: &transcript)
    #expect(transcript.count == 1)
    #expect(transcript[0].text == "今日は晴れです。明日は雨です。")
}

@Test func sweepOnlyRemovesContainedSiblings() {
    // Two existing segments overlap in time with the incoming but the
    // incoming only contains ONE of them. The non-contained one should
    // remain.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let a = TranscriptSegment(
        source: .microphone,
        text: "明日は雨で、傘が必要です。",
        startTime: now,
        endTime: now.addingTimeInterval(3),
        isFinal: true
    )
    let b = TranscriptSegment(
        source: .microphone,
        text: "ところで会議は午後3時から。",
        startTime: now.addingTimeInterval(3),
        endTime: now.addingTimeInterval(6),
        isFinal: true
    )
    var transcript: [TranscriptSegment] = [a, b]
    // Refinement of just b, extends the trailing portion — fully contains
    // b's existing text and does NOT contain a's text.
    let refinedB = TranscriptSegment(
        source: .microphone,
        text: "ところで会議は午後3時から。早めに集合しましょう。",
        startTime: now.addingTimeInterval(3),
        endTime: now.addingTimeInterval(7),
        isFinal: true
    )
    _ = deduper.merge(refinedB, into: &transcript)
    #expect(transcript.count == 2)
    #expect(transcript[0].text == "明日は雨で、傘が必要です。")
    #expect(transcript[1].text == "ところで会議は午後3時から。早めに集合しましょう。")
}

// MARK: - Directional refinement matches

@Test func mergesNameRefinementWithExtraSyllable() {
    // Real-world: cycle N emits "日程 新山貴です" (Whisper truncated the
    // surname), cycle N+1 refines to "日程 新山貴樹です". Symmetric
    // Jaccard between these is < 0.7 (the union picks up the extra
    // bigram), so the old code left both as separate rows. Directional
    // containment notes the shorter's bigrams are ≥ 70 % covered by
    // the longer and merges.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .system,
        text: "日程 新山貴です",
        startTime: now,
        endTime: now.addingTimeInterval(2),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .system,
            text: "日程 新山貴樹です",
            startTime: now,
            endTime: now.addingTimeInterval(2.5),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 1)
    #expect(transcript[0].text == "日程 新山貴樹です")
}

@Test func mergesNumericRefinementInLongSentence() {
    // Real-world: "10年ぶりに1、6月期ですけれども" → "1年ぶりに1、6月期ですけれども、".
    // One char difference + trailing 、. Symmetric Jaccard dips below
    // 0.7; directional containment sits at ~0.875.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .system,
        text: "10年ぶりに1、6月期ですけれども",
        startTime: now,
        endTime: now.addingTimeInterval(3),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .system,
            text: "1年ぶりに1、6月期ですけれども、",
            startTime: now.addingTimeInterval(0.5),
            endTime: now.addingTimeInterval(3.5),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 1)
    #expect(transcript[0].text == "1年ぶりに1、6月期ですけれども、")
}

@Test func mergesPartialContinuationOfPriorSentence() {
    // Real-world: "私の方からご説明させていただいたのは" emitted in cycle
    // N, then "させていただいたのは、" emitted next cycle. The shorter
    // is fully a tail of the longer (plus a trailing 、). Directional
    // containment sees the smaller (9 bigrams) is ~89 % covered.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .microphone,
        text: "私の方からご説明させていただいたのは",
        startTime: now,
        endTime: now.addingTimeInterval(4),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .microphone,
            text: "させていただいたのは、",
            startTime: now.addingTimeInterval(2),
            endTime: now.addingTimeInterval(4.5),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 1)
    // Smart concat preserves the longer's prefix and the shorter's
    // trailing punctuation, since both sides have unique content the
    // other lacks. The 、 from the trailing fragment is kept.
    #expect(transcript[0].text == "私の方からご説明させていただいたのは、")
}

// MARK: - Time-overlap + LCS smart concat

@Test func mergesViaTimeOverlapWhenTextSimilarityFails() {
    // Real-world: cycle N decodes audio as "都がですね10年ぶりに" at
    // [t0..t0+3]; cycle N+1 decodes the same audio region as
    // "1年ぶりに1、6月期…" at [t0..t0+12] (extended chunking).
    // Symmetric Jaccard / directional bigram both miss because text
    // diverges too much. Time-overlap signal catches it.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .system,
        text: "都がですね10年ぶりに",
        startTime: now,
        endTime: now.addingTimeInterval(3),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .system,
            text: "1年ぶりに1、6月期ですけれども、プラス0.3と、プラスに転じたということをお伝えをいたしました。",
            startTime: now,
            endTime: now.addingTimeInterval(12),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 1)
    // The merge picks the longer text (LCS sits in the middle of the
    // shorter, mid-sentence — splicing is too risky there).
    #expect(transcript[0].text.contains("プラスに転じた"))
}

@Test func smartConcatPreservesUniquePrefixAndSuffix() {
    // The "rolling overlap" pattern: existing ends with the LCS, new
    // starts with it. The merge splices unique prefix + LCS + unique
    // suffix so neither side's content is dropped.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .microphone,
        text: "私の方からご説明させていただいたのは",
        startTime: now,
        endTime: now.addingTimeInterval(4),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .microphone,
            text: "させていただいたのは、先日国が発表されました",
            startTime: now.addingTimeInterval(2),
            endTime: now.addingTimeInterval(8),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 1)
    // Both sides' unique content is preserved.
    #expect(transcript[0].text == "私の方からご説明させていただいたのは、先日国が発表されました")
}

@Test func timeOverlapDoesNotMergeNonOverlappingSegments() {
    // Adjacent but non-overlapping segments must stay separate — they
    // represent different utterances.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .microphone,
        text: "おはようございます",
        startTime: now,
        endTime: now.addingTimeInterval(2),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .microphone,
            text: "予算会議を始めましょう",
            // 1 second gap — no overlap.
            startTime: now.addingTimeInterval(3),
            endTime: now.addingTimeInterval(6),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 2)
}

@Test func longestCommonSubstringFindsBoundaryRun() {
    let result = TranscriptDeduper.longestCommonSubstring(
        "私の方からご説明させていただいたのは",
        "させていただいたのは、先日国が発表されました"
    )
    #expect(result.length == 10) // させていただいたのは
    // In a, it starts at char index 8 (after "私の方からご説明")
    #expect(result.aOffset == 8)
    // In b, it starts at index 0.
    #expect(result.bOffset == 0)
}

@Test func directionalFloorIgnoresTrivialBigramMatchWithDistinctText() {
    // Guard against false positives from the directional rule on very
    // short texts. The shorter side has < 3 bigrams here, so mergeSignal
    // falls back to symmetric similarity only — and the two segments
    // share neither a substring nor enough tokens to trip the threshold.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript = [TranscriptSegment(
        source: .microphone,
        text: "了解",
        startTime: now,
        endTime: now.addingTimeInterval(1),
        isFinal: true
    )]
    _ = deduper.merge(
        TranscriptSegment(
            source: .microphone,
            text: "明日の予算会議について議論しましょう",
            startTime: now.addingTimeInterval(5),
            endTime: now.addingTimeInterval(11),
            isFinal: true
        ),
        into: &transcript
    )
    #expect(transcript.count == 2)
}

@Test func sweepRemovesEarlierMisheardCyclesByBigramOverlap() {
    // Real-world failure mode: Whisper iterates on the same audio across
    // multiple cycles, slowly refining a misheard word and growing the
    // sentence. Each emission is a separate entry until the final
    // combined version arrives. Strict substring containment wouldn't
    // catch the early "高橋総理" (misheard) version because the final
    // says "高市総理" and adds 、. The bigram-overlap sweep does.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript: [TranscriptSegment] = [
        TranscriptSegment(source: .system, text: "今回高橋総理と面会されまして", startTime: now, endTime: now.addingTimeInterval(3), isFinal: true),
        TranscriptSegment(source: .system, text: "今回高市総理と面会されましたけど", startTime: now.addingTimeInterval(1), endTime: now.addingTimeInterval(4), isFinal: true),
        TranscriptSegment(source: .system, text: "どのような話が相変わらされたのかお聞かせください", startTime: now.addingTimeInterval(4), endTime: now.addingTimeInterval(8), isFinal: true),
    ]
    let final = TranscriptSegment(
        source: .system,
        text: "今回、高市総理と面会されまして、どのような話が相変わらされたのかお聞かせください。",
        startTime: now,
        endTime: now.addingTimeInterval(8),
        isFinal: true
    )
    _ = deduper.merge(final, into: &transcript)
    #expect(transcript.count == 1)
    #expect(transcript[0].text == "今回、高市総理と面会されまして、どのような話が相変わらされたのかお聞かせください。")
}

@Test func sweepDoesNotRemoveUnrelatedShortSegment() {
    // Two short utterances next to a long merge that doesn't subsume
    // either. They have low bigram overlap with the merge → keep them.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript: [TranscriptSegment] = [
        TranscriptSegment(source: .microphone, text: "おはようございます", startTime: now, endTime: now.addingTimeInterval(2), isFinal: true),
        TranscriptSegment(source: .microphone, text: "今日もよろしくお願いします", startTime: now.addingTimeInterval(2), endTime: now.addingTimeInterval(4), isFinal: true),
    ]
    let unrelatedRefinement = TranscriptSegment(
        source: .microphone,
        text: "予算について議論を続けましょう、まず売上の話から。",
        startTime: now.addingTimeInterval(4),
        endTime: now.addingTimeInterval(10),
        isFinal: true
    )
    _ = deduper.merge(unrelatedRefinement, into: &transcript)
    #expect(transcript.count == 3)
    #expect(transcript[0].text == "おはようございます")
    #expect(transcript[1].text == "今日もよろしくお願いします")
}

@Test func sweepCollapsesThreeFragmentsIntoOne() {
    // Stress case: three earlier fragments all subsumed by a single
    // late-cycle combined emission. The deduper picks the newest as the
    // primary, merges the incoming into it, and removes the other two.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var transcript: [TranscriptSegment] = [
        TranscriptSegment(source: .system, text: "今日は", startTime: now, endTime: now.addingTimeInterval(1), isFinal: true),
        TranscriptSegment(source: .system, text: "晴れの予報で", startTime: now.addingTimeInterval(1), endTime: now.addingTimeInterval(2), isFinal: true),
        TranscriptSegment(source: .system, text: "傘は不要です。", startTime: now.addingTimeInterval(2), endTime: now.addingTimeInterval(3), isFinal: true),
    ]
    let combined = TranscriptSegment(
        source: .system,
        text: "今日は晴れの予報で傘は不要です。",
        startTime: now,
        endTime: now.addingTimeInterval(3),
        isFinal: true
    )
    _ = deduper.merge(combined, into: &transcript)
    #expect(transcript.count == 1)
    #expect(transcript[0].text == "今日は晴れの予報で傘は不要です。")
}

@Test func confirmedNotDowngradedByLongerUnconfirmedRewrite() {
    // Edge case: the unconfirmed rewrite is LONGER than the confirmed
    // text. Without the confirmation policy, the deduper's
    // "preferLonger" rule would replace the confirmed text.
    let deduper = TranscriptDeduper()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let confirmed = TranscriptSegment(
        source: .microphone,
        text: "決定事項です",
        startTime: now,
        endTime: now.addingTimeInterval(2),
        isFinal: true,
        isConfirmed: true
    )
    var transcript = [confirmed]
    let longerUnconfirmed = TranscriptSegment(
        source: .microphone,
        text: "決定事項ですよね今のところ",
        startTime: now,
        endTime: now.addingTimeInterval(2.5),
        isFinal: false,
        isConfirmed: false
    )
    _ = deduper.merge(longerUnconfirmed, into: &transcript)
    #expect(transcript[0].text == "決定事項です")
    #expect(transcript[0].isConfirmed == true)
}

@Test func transcriptSegmentDecodesLegacyJSONWithoutIsConfirmedField() throws {
    // Saved sessions from before isConfirmed existed must read as
    // confirmed (the saved transcript is the final version).
    let legacy = #"""
    {
      "id":"00000000-0000-0000-0000-000000000001",
      "source":"microphone",
      "text":"hello",
      "startTime":"2026-01-01T00:00:00Z",
      "endTime":"2026-01-01T00:00:02Z",
      "isFinal":true
    }
    """#.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let seg = try decoder.decode(TranscriptSegment.self, from: legacy)
    #expect(seg.isConfirmed == true)
    #expect(seg.text == "hello")
}

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
    _ = dedup.merge(segment("田中さんは来週金曜日までに更新してください", start: 0, duration: 3), into: &list)
    // Distinct time range — two unrelated utterances back-to-back.
    let outcome = dedup.merge(segment("予算については来週改めて議論することにします", start: 4, duration: 3), into: &list)
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
    // Each segment in its own non-overlapping time slot so the
    // lookback-window cap is what gates the lookup, not the time-
    // overlap signal.
    _ = dedup.merge(segment("alpha beta gamma", start: 0, duration: 2), into: &list)
    _ = dedup.merge(segment("delta epsilon", start: 3, duration: 2), into: &list)
    _ = dedup.merge(segment("zeta eta theta", start: 6, duration: 2), into: &list)
    // "alpha beta gamma" sits outside the 2-entry lookback window now,
    // and its [0..2] time range no longer touches the latest entries'
    // ranges, so a repeat at a fresh time slot must append.
    let outcome = dedup.merge(segment("alpha beta gamma", start: 9, duration: 2), into: &list)
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
