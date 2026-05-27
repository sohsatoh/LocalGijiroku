import Testing
import Foundation
@testable import GijirokuCore

private func seg(
    _ text: String,
    source: AudioSource = .microphone,
    speaker: String? = nil,
    start: TimeInterval,
    duration: TimeInterval = 1,
    confirmed: Bool = true
) -> TranscriptSegment {
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    return TranscriptSegment(
        source: source,
        speaker: speaker,
        text: text,
        startTime: origin.addingTimeInterval(start),
        endTime: origin.addingTimeInterval(start + duration),
        isFinal: confirmed,
        isConfirmed: confirmed
    )
}

@Test func emptyInputYieldsNoTurns() {
    #expect(TranscriptTurnGrouping.turns(from: []).isEmpty)
}

@Test func consecutiveSameSpeakerSegmentsCollapseIntoOneTurn() {
    let segments = [
        seg("最初の発言", speaker: "A", start: 0),
        seg("続き", speaker: "A", start: 1.2),
        seg("もう一つ", speaker: "A", start: 2.4),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 1)
    #expect(turns[0].segments.count == 3)
    // Smart concat joins CJK runs without spaces — "今日は元気です" reads
    // wrong with an interstitial space.
    #expect(turns[0].text == "最初の発言続きもう一つ")
    #expect(turns[0].speaker == "A")
}

@Test func speakerChangeStartsNewTurn() {
    let segments = [
        seg("Aの発言", speaker: "A", start: 0),
        seg("Bの発言", speaker: "B", start: 1.2),
        seg("Aがまた", speaker: "A", start: 2.4),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 3)
    #expect(turns.map(\.speaker) == ["A", "B", "A"])
}

@Test func sourceChangeStartsNewTurn() {
    let segments = [
        seg("mic", source: .microphone, start: 0),
        seg("system", source: .system, start: 1.2),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 2)
    #expect(turns[0].source == .microphone)
    #expect(turns[1].source == .system)
}

@Test func longTimeGapStartsNewTurn() {
    // 10 s gap between two same-speaker segments — exceeds the 5 s
    // default so they split into separate turns.
    let segments = [
        seg("前半", speaker: "A", start: 0, duration: 2),
        seg("ずっと後", speaker: "A", start: 12, duration: 2),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 2)
}

@Test func liveTailAttachesToMostRecentTurnFromSameSource() {
    let segments = [
        seg("mic confirmed", source: .microphone, start: 0),
        seg("system confirmed", source: .system, start: 5),
    ]
    let tail = seg("system tail", source: .system, start: 6, confirmed: false)
    let turns = TranscriptTurnGrouping.turns(
        from: segments,
        liveTail: [.system: tail]
    )
    #expect(turns.count == 2)
    // mic turn unaffected
    #expect(turns[0].source == .microphone)
    #expect(turns[0].liveTail == nil)
    // system turn carries the tail
    #expect(turns[1].source == .system)
    #expect(turns[1].liveTail?.text == "system tail")
}

@Test func liveTailWithoutAnyConfirmedTurnSynthesizesAShellTurn() {
    // First inference cycle, before any confirmed segment exists for the
    // source — we still want the live tail to render so the user sees
    // text immediately.
    let tail = seg("はじめての音声", source: .microphone, start: 0, confirmed: false)
    let turns = TranscriptTurnGrouping.turns(
        from: [],
        liveTail: [.microphone: tail]
    )
    #expect(turns.count == 1)
    #expect(turns[0].segments.isEmpty)
    #expect(turns[0].liveTail?.text == "はじめての音声")
}

@Test func liveTailDoesNotAttachToWrongSourceTurn() {
    let segments = [seg("mic only", source: .microphone, start: 0)]
    let tail = seg("system tail", source: .system, start: 1, confirmed: false)
    let turns = TranscriptTurnGrouping.turns(
        from: segments,
        liveTail: [.system: tail]
    )
    // mic turn untouched, virtual system turn at the tail's start time
    #expect(turns.count == 2)
    let micTurn = turns.first(where: { $0.source == .microphone })
    let sysTurn = turns.first(where: { $0.source == .system })
    #expect(micTurn?.liveTail == nil)
    #expect(sysTurn?.liveTail?.text == "system tail")
    #expect(sysTurn?.segments.isEmpty == true)
}

// MARK: - Paragraph splitting

@Test func paragraphsSplitAtJapaneseSentenceTerminators() {
    let segments = [
        seg("今日は晴れです。", speaker: "A", start: 0),
        seg("明日は雨の予報です。", speaker: "A", start: 1),
        seg("傘を持って行きます", speaker: "A", start: 2),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 1)
    let paragraphs = turns[0].paragraphs
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0] == "今日は晴れです。")
    #expect(paragraphs[1] == "明日は雨の予報です。")
    #expect(paragraphs[2] == "傘を持って行きます")
}

@Test func paragraphsSplitAtAsciiSentenceTerminators() {
    let segments = [
        seg("Hello world.", start: 0),
        seg("How are you?", start: 1),
        seg("Im fine", start: 2),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    let paragraphs = turns[0].paragraphs
    #expect(paragraphs.count == 3)
    #expect(paragraphs[2] == "Im fine")
}

@Test func paragraphsBreakOnLongInterSegmentGap() {
    // Whisper ja sometimes emits no terminal punctuation at all. A long
    // pause between segments should still produce a paragraph break so
    // the .turns block doesn't collapse into a wall of text.
    let segments = [
        seg("最初の話題について話します", speaker: "A", start: 0, duration: 1),
        // 2-second gap (> maxIntraParagraphGap 1.5) — paragraph break
        seg("次は別の話題に移ります", speaker: "A", start: 3, duration: 1),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 1)
    let paragraphs = turns[0].paragraphs
    #expect(paragraphs.count == 2)
    #expect(paragraphs[0] == "最初の話題について話します")
    #expect(paragraphs[1] == "次は別の話題に移ります")
}

@Test func paragraphsBreakAtCharacterCapWhenNoPunctuation() {
    // Pure non-stop Whisper output (no 。 at all). Once the running
    // character count crosses maxParagraphCharacters the next segment
    // boundary must force a paragraph break, otherwise the entire
    // turn is one unreadable block.
    let longSegmentText = String(repeating: "あ", count: 100)
    let segments = [
        seg(longSegmentText, speaker: "A", start: 0, duration: 1),
        // Same paragraph since first seg alone is < 180 chars (100). Add
        // a second seg of 100 chars at small gap — combined 200 > 180,
        // so the post-break fires.
        seg(longSegmentText, speaker: "A", start: 1.2, duration: 1),
        seg("追加", speaker: "A", start: 2.4, duration: 1),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns.count == 1)
    let paragraphs = turns[0].paragraphs
    // Expect at least 2 paragraphs: first hits the cap after seg 2,
    // and seg 3 starts a new paragraph.
    #expect(paragraphs.count >= 2)
}

@Test func paragraphsKeepShortContinuousRunInSingleBlock() {
    // Sanity: short, gap-less, no-punctuation runs stay together. The
    // new break triggers must not over-fire on normal short content.
    let segments = [
        seg("短い", speaker: "A", start: 0, duration: 0.3),
        seg("発言", speaker: "A", start: 0.4, duration: 0.3),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    #expect(turns[0].paragraphs.count == 1)
}

@Test func paragraphsKeepMidSentenceCommasInSameBlock() {
    // 、 is a mid-sentence comma, not a terminator. Two segments that
    // end with 、 should join into one paragraph.
    let segments = [
        seg("天気は良いが、", start: 0),
        seg("風が強い。", start: 1),
    ]
    let turns = TranscriptTurnGrouping.turns(from: segments)
    let paragraphs = turns[0].paragraphs
    #expect(paragraphs.count == 1)
    #expect(paragraphs[0] == "天気は良いが、風が強い。")
}

@Test func smartConcatJoinsCJKWithoutSpace() {
    let result = TranscriptTurn.smartConcat(["今日は", "元気です"])
    #expect(result == "今日は元気です")
}

@Test func smartConcatAddsSpaceAtAsciiWordBoundary() {
    // Whisper sometimes returns leading-spaced ASCII segments, but the
    // smart concat should not depend on those — it should add its own
    // separator when both adjacent characters are ASCII letters.
    let result = TranscriptTurn.smartConcat(["hello", "world"])
    #expect(result == "hello world")
}

@Test func smartConcatDoesNotAddSpaceBeforePunctuation() {
    let result = TranscriptTurn.smartConcat(["Hello", ", world"])
    // Second segment starts with ',' not a letter → no separator.
    #expect(result == "Hello, world")
}

@Test func smartConcatStripsWhitespaceFromEachSegment() {
    let result = TranscriptTurn.smartConcat([" hello ", " world "])
    #expect(result == "hello world")
}

@Test func headingBoundarySplitsOtherwiseMergeableTurn() {
    // Same speaker, same source, gap well under maxIntraTurnGap — would
    // normally collapse into one turn. A heading anchored between the
    // two segments must force the split so the `.turns` layout doesn't
    // render the heading orphaned next to a single block that
    // straddles it.
    let segments = [
        seg("前半1", speaker: "A", start: 0, duration: 1),
        seg("前半2", speaker: "A", start: 1.2, duration: 1),
        seg("後半1", speaker: "A", start: 3, duration: 1),
        seg("後半2", speaker: "A", start: 4.2, duration: 1),
    ]
    // Anchor between the second and third segment (2.2 < 2.5 < 3).
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    let heading = TranscriptHeading(
        text: "新しい話題",
        startTime: origin.addingTimeInterval(2.5)
    )
    let turns = TranscriptTurnGrouping.turns(from: segments, headings: [heading])
    #expect(turns.count == 2)
    #expect(turns[0].segments.map(\.text) == ["前半1", "前半2"])
    #expect(turns[1].segments.map(\.text) == ["後半1", "後半2"])
}

@Test func headingAtExactSegmentBoundaryStillSplits() {
    // Heading anchored at exactly seg2.startTime (the conservative
    // boundary the AppModel emits as `max(endTime)+0.001`). The
    // splitter must treat this as "belongs at the start of the new
    // section", i.e. split.
    let segments = [
        seg("前", speaker: "A", start: 0, duration: 1),
        seg("後", speaker: "A", start: 2, duration: 1),
    ]
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    let heading = TranscriptHeading(
        text: "境界",
        startTime: origin.addingTimeInterval(2)
    )
    let turns = TranscriptTurnGrouping.turns(from: segments, headings: [heading])
    #expect(turns.count == 2)
}

@Test func headingDetachesLiveTailFromPriorTurn() {
    // Confirmed turn ends at t=2. Tail begins at t=3 (Whisper's rolling
    // tail for the same source, still streaming). A heading anchored
    // between them must NOT carry the tail into the prior turn —
    // otherwise the streaming text continues to render above the
    // heading divider, which is the exact "字幕が前の heading で続く"
    // bug.
    let confirmed = [
        seg("前半1", speaker: "A", start: 0, duration: 1),
        seg("前半2", speaker: "A", start: 1, duration: 1),
    ]
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    let tail = TranscriptSegment(
        source: .microphone,
        speaker: "A",
        text: "進行中...",
        startTime: origin.addingTimeInterval(3),
        endTime: origin.addingTimeInterval(3.5),
        isFinal: false,
        isConfirmed: false
    )
    let heading = TranscriptHeading(
        text: "新話題",
        startTime: origin.addingTimeInterval(2.5)
    )
    let turns = TranscriptTurnGrouping.turns(
        from: confirmed,
        liveTail: [.microphone: tail],
        headings: [heading]
    )
    // Expect two turns: the prior confirmed run (no tail), and a virtual
    // turn for the tail (no confirmed segments). Sorted by startTime so
    // the heading slots between them.
    #expect(turns.count == 2)
    #expect(turns[0].liveTail == nil)
    #expect(turns[0].segments.map(\.text) == ["前半1", "前半2"])
    #expect(turns[1].liveTail?.text == "進行中...")
    #expect(turns[1].segments.isEmpty)
    #expect(turns[1].startTime > heading.startTime)
}

@Test func liveTailAttachesNormallyWhenNoHeadingBetween() {
    // Sanity: with no heading between the prior turn and the tail,
    // the original attach behaviour must remain — same-source tail
    // flows inline at the end of the most recent turn.
    let confirmed = [
        seg("確定", speaker: "A", start: 0, duration: 1),
    ]
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    let tail = TranscriptSegment(
        source: .microphone,
        speaker: "A",
        text: "続き...",
        startTime: origin.addingTimeInterval(1.5),
        endTime: origin.addingTimeInterval(2),
        isFinal: false,
        isConfirmed: false
    )
    let turns = TranscriptTurnGrouping.turns(
        from: confirmed,
        liveTail: [.microphone: tail]
    )
    #expect(turns.count == 1)
    #expect(turns[0].liveTail?.text == "続き...")
}

@Test func headingOutsideTurnRangeDoesNotForceSplit() {
    // Heading well before all segments — no segment pair straddles it,
    // so the grouper should still produce a single turn.
    let segments = [
        seg("a", speaker: "A", start: 100, duration: 1),
        seg("b", speaker: "A", start: 101.2, duration: 1),
    ]
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    let heading = TranscriptHeading(text: "古い", startTime: origin)
    let turns = TranscriptTurnGrouping.turns(from: segments, headings: [heading])
    #expect(turns.count == 1)
}

@Test func turnIdIsStableAcrossAppendsToSameSpeaker() {
    // SwiftUI uses Turn.id for diffing; appending a new same-speaker
    // segment must keep the same id so the existing block animates
    // gracefully instead of being torn down and recreated.
    var segments = [
        seg("最初", speaker: "A", start: 0),
        seg("二発目", speaker: "A", start: 1.2),
    ]
    let beforeID = TranscriptTurnGrouping.turns(from: segments)[0].id
    segments.append(seg("三発目", speaker: "A", start: 2.4))
    let afterID = TranscriptTurnGrouping.turns(from: segments)[0].id
    #expect(beforeID == afterID)
}
