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

@Test func exportMarkdownIncludesAllSections() {
    let store = FileSessionStore(directory: tempDir())
    let session = Session(
        title: "Demo",
        transcript: [.init(source: .system, text: "hi", startTime: .now, endTime: .now, isFinal: true)],
        summary: CumulativeSummary(sections: [.init(title: "Topic", bullets: ["point a"])]),
        events: [.init(kind: .question, text: "what?")]
    )
    let md = store.exportMarkdown(session)
    #expect(md.contains("# Demo"))
    #expect(md.contains("## Summary"))
    #expect(md.contains("### Topic"))
    #expect(md.contains("- point a"))
    #expect(md.contains("## Events"))
    #expect(md.contains("what?"))
    #expect(md.contains("## Transcript"))
    #expect(md.contains("[system] hi"))
}

@Test func loadReturnsNilForMissingSession() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileSessionStore(directory: dir)
    let result = try store.load(id: UUID())
    #expect(result == nil)
}
