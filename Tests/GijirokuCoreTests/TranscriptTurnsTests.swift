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
    #expect(turns[0].text == "最初の発言 続き もう一つ")
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
