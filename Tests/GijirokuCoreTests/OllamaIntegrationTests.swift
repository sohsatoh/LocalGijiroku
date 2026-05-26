import Testing
import Foundation
@testable import GijirokuCore

// These tests require:
//   - Ollama running on http://127.0.0.1:11434
//   - qwen2.5:7b model pulled
//   - RUN_OLLAMA_TESTS=1 env var set
// They are skipped by default to keep the regular test suite hermetic.

private func ollamaEnabled() -> Bool {
    ProcessInfo.processInfo.environment["RUN_OLLAMA_TESTS"] == "1"
}

@Test(.enabled(if: ollamaEnabled()))
func ollamaSummaryRoundTripJapanese() async throws {
    let client = OllamaClient()
    let engine = SummaryEngine(client: client, config: .init(model: "qwen2.5:7b", language: "Japanese"))
    let now = Date()
    let segments: [TranscriptSegment] = [
        .init(source: .system, text: "今日の議題は次のスプリントの計画です。", startTime: now, endTime: now.addingTimeInterval(3), isFinal: true),
        .init(source: .microphone, text: "新機能の優先順位を決めましょう。検索機能とエクスポート機能のどちらを先に作るか議論したい。", startTime: now.addingTimeInterval(3), endTime: now.addingTimeInterval(8), isFinal: true),
    ]
    let summary = try await engine.ingest(newSegments: segments)
    #expect(!summary.sections.isEmpty, "Expected at least one summary section")
}

@Test(.enabled(if: ollamaEnabled()))
func ollamaEventExtractorJapanese() async throws {
    let client = OllamaClient()
    let extractor = EventExtractor(client: client, config: .init(model: "qwen2.5:7b"))
    let now = Date()
    let segments: [TranscriptSegment] = [
        .init(source: .microphone, text: "田中さんはドキュメントを金曜日までに更新してください。", startTime: now, endTime: now.addingTimeInterval(4), isFinal: true),
        .init(source: .system, text: "次回ミーティングはどの日にしますか？", startTime: now.addingTimeInterval(4), endTime: now.addingTimeInterval(7), isFinal: true),
    ]
    let events = try await extractor.extract(from: segments)
    #expect(!events.isEmpty, "Expected at least one extracted event")
}
