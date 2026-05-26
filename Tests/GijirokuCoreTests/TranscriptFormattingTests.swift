import Testing
import Foundation
@testable import GijirokuCore

private func segment(
    _ text: String,
    source: AudioSource = .microphone,
    speaker: String? = nil
) -> TranscriptSegment {
    let origin = Date(timeIntervalSinceReferenceDate: 0)
    return TranscriptSegment(
        source: source,
        speaker: speaker,
        text: text,
        startTime: origin,
        endTime: origin.addingTimeInterval(1),
        isFinal: false
    )
}

@Test func prefixesLineWithSpeakerLabel() {
    let line = TranscriptFormatting.toPromptLines([
        segment("提案書を月曜までに", speaker: "Speaker 1")
    ])
    #expect(line == "[Speaker 1] 提案書を月曜までに")
}

@Test func omitsBracketWhenNoSpeaker() {
    // Critical regression guard: previously the formatter fell back to
    // `source.rawValue` so this line became `[system] ...`, which then
    // leaked into LLM-generated bullets as `[system]` prefixes.
    let line = TranscriptFormatting.toPromptLines([
        segment("価格をどうするか議論", source: .system, speaker: nil)
    ])
    #expect(line == "価格をどうするか議論")
    #expect(!line.contains("[system]"))
    #expect(!line.contains("[microphone]"))
}

@Test func omitsBracketWhenSpeakerIsEmptyString() {
    let line = TranscriptFormatting.toPromptLines([
        segment("テスト", source: .microphone, speaker: "")
    ])
    #expect(line == "テスト")
}

@Test func joinsMultipleSegmentsWithNewlines() {
    let out = TranscriptFormatting.toPromptLines([
        segment("一行目", speaker: "Speaker 1"),
        segment("二行目", speaker: nil),
        segment("三行目", speaker: "あなた")
    ])
    #expect(out == "[Speaker 1] 一行目\n二行目\n[あなた] 三行目")
}
