import Testing
import Foundation
@testable import GijirokuCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gijiroku-test-\(UUID().uuidString)")
    return url
}

@Test func savesAndLoadsSessionRoundTrip() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileSessionStore(directory: dir)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let original = Session(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        title: "Test",
        startedAt: now,
        endedAt: now.addingTimeInterval(60),
        transcript: [
            .init(source: .microphone, text: "hello", startTime: now, endTime: now.addingTimeInterval(2), isFinal: true),
        ],
        summary: CumulativeSummary(sections: [.init(title: "Intro", bullets: ["greeting"])]),
        events: [.init(kind: .action, text: "do thing", owner: "alice")]
    )

    try store.save(original)
    let loaded = try #require(try store.load(id: original.id))
    #expect(loaded.title == "Test")
    #expect(loaded.transcript.count == 1)
    #expect(loaded.summary.sections.first?.title == "Intro")
    #expect(loaded.events.first?.owner == "alice")
}

@Test func sessionDecoderDefaultsMissingHeadingsToEmpty() throws {
    // Sessions written before the heading detector existed don't carry
    // a `headings` field. The custom decoder must surface them with an
    // empty array instead of throwing — otherwise the sidebar drops
    // every legacy recording.
    let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    let json = #"""
    {
      "id": "\#(id.uuidString)",
      "title": "Legacy",
      "startedAt": 700000000,
      "transcript": [],
      "summary": {"sections": [], "lastUpdated": 700000000},
      "events": []
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let session = try decoder.decode(Session.self, from: Data(json.utf8))
    #expect(session.id == id)
    #expect(session.title == "Legacy")
    #expect(session.headings.isEmpty)
}

@Test func sessionRoundTripsHeadingsThroughCodable() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileSessionStore(directory: dir)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let original = Session(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        title: "Heading test",
        startedAt: now,
        endedAt: now.addingTimeInterval(120),
        transcript: [],
        summary: CumulativeSummary(),
        events: [],
        headings: [
            TranscriptHeading(text: "市場分析", startTime: now),
            TranscriptHeading(text: "価格戦略", startTime: now.addingTimeInterval(60)),
        ]
    )

    try store.save(original)
    let loaded = try #require(try store.load(id: original.id))
    #expect(loaded.headings.count == 2)
    #expect(loaded.headings.map(\.text) == ["市場分析", "価格戦略"])
    #expect(loaded.headings.last?.startTime == now.addingTimeInterval(60))
}

@Test func sessionRoundTripsAgendaSuggestionsThroughCodable() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileSessionStore(directory: dir)

    let original = Session(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        title: "Agenda suggestion test",
        events: [
            MeetingEvent(kind: .question, text: "期限はいつか"),
            MeetingEvent(kind: .agendaSuggestion, text: "未討議のリスク確認"),
        ]
    )

    try store.save(original)
    let loaded = try #require(try store.load(id: original.id))
    #expect(loaded.events.count == 2)
    #expect(loaded.events.map(\.kind) == [.question, .agendaSuggestion])
}

@Test func listReturnsSavedSessionsNewestFirst() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileSessionStore(directory: dir)

    let older = Session(title: "Older", startedAt: Date(timeIntervalSince1970: 1_000))
    let newer = Session(title: "Newer", startedAt: Date(timeIntervalSince1970: 9_000))
    try store.save(older)
    try store.save(newer)

    let rows = try store.list()
    #expect(rows.count == 2)
    #expect(rows[0].title == "Newer")
    #expect(rows[1].title == "Older")
}

@Test func exportMarkdownIncludesSummaryAndTaskSections() {
    let store = FileSessionStore(directory: tempDir())
    let session = Session(
        title: "Demo",
        transcript: [.init(source: .system, text: "hi", startTime: .now, endTime: .now, isFinal: true)],
        summary: CumulativeSummary(sections: [.init(title: "Topic", bullets: ["point a"])]),
        events: [
            .init(kind: .question, text: "what?"),
            .init(kind: .action, text: "ship it", owner: "alice", dueDate: "2026-06-01"),
            .init(kind: .decision, text: "go ahead"),
        ]
    )
    let md = store.exportMarkdown(session)
    #expect(md.contains("# Demo"))
    #expect(md.contains("## Summary"))
    #expect(md.contains("### Topic"))
    #expect(md.contains("- point a"))
    #expect(md.contains("## Action Items"))
    #expect(md.contains("ship it"))
    #expect(md.contains("(@alice)"))
    #expect(md.contains("due 2026-06-01"))
    #expect(md.contains("## Decisions"))
    #expect(md.contains("go ahead"))
    #expect(md.contains("## Questions"))
    #expect(md.contains("what?"))
    // Transcript is NOT included by default — keeps shared notes concise.
    #expect(!md.contains("## Transcript"))
    #expect(!md.contains("[system] hi"))
}

@Test func loadReturnsNilForMissingSession() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileSessionStore(directory: dir)
    let result = try store.load(id: UUID())
    #expect(result == nil)
}
