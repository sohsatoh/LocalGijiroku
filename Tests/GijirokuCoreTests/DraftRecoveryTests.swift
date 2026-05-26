import Testing
import Foundation
@testable import GijirokuCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gijiroku-test-\(UUID().uuidString)")
}

private struct StoresFixture {
    let sessions: FileSessionStore
    let drafts: FileSessionStore
    let sessionsDir: URL
    let draftsDir: URL

    init() {
        let base = tempDir()
        sessionsDir = base.appendingPathComponent("Sessions")
        draftsDir = base.appendingPathComponent("Drafts")
        sessions = FileSessionStore(directory: sessionsDir)
        drafts = FileSessionStore(directory: draftsDir)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sessionsDir.deletingLastPathComponent())
    }
}

@Test func recoveryPromotesOrphanedDraftIntoSessions() throws {
    let f = StoresFixture()
    defer { f.cleanup() }
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let draft = Session(
        id: id,
        title: "録音中（自動保存）",
        startedAt: now,
        endedAt: nil, // crash happened mid-recording
        transcript: [.init(source: .microphone, text: "hello", startTime: now, endTime: now.addingTimeInterval(2), isFinal: true)]
    )
    try f.drafts.save(draft)
    let promoted = try DraftRecovery.promoteOrphans(
        from: f.drafts,
        into: f.sessions,
        recoveredPrefix: "[復元] ",
        now: now.addingTimeInterval(3600)
    )
    #expect(promoted == 1)
    // Draft is gone; session is present with prefixed title and endedAt set.
    #expect(try f.drafts.list().isEmpty)
    let recovered = try #require(try f.sessions.load(id: id))
    #expect(recovered.title == "[復元] 録音中（自動保存）")
    #expect(recovered.endedAt == now.addingTimeInterval(3600))
    #expect(recovered.transcript.count == 1)
}

@Test func recoveryIsNoOpWhenNoDrafts() throws {
    let f = StoresFixture()
    defer { f.cleanup() }
    let promoted = try DraftRecovery.promoteOrphans(
        from: f.drafts,
        into: f.sessions,
        recoveredPrefix: "[復元] "
    )
    #expect(promoted == 0)
}

@Test func recoverySkipsPromotionWhenSessionAlreadyExists() throws {
    // Simulates the race where persistFinalSession completed its save but
    // failed to delete the draft. Recovery must NOT overwrite the polished
    // final with the stale draft.
    let f = StoresFixture()
    defer { f.cleanup() }
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let staleDraft = Session(
        id: id,
        title: "録音中（自動保存）",
        startedAt: now,
        transcript: [.init(source: .microphone, text: "old draft text", startTime: now, endTime: now, isFinal: true)]
    )
    let polishedFinal = Session(
        id: id,
        title: "2026-05-27 重要なミーティング",
        startedAt: now,
        endedAt: now.addingTimeInterval(60),
        transcript: [
            .init(source: .microphone, text: "polished text 1", startTime: now, endTime: now, isFinal: true),
            .init(source: .microphone, text: "polished text 2", startTime: now, endTime: now, isFinal: true),
        ]
    )
    try f.sessions.save(polishedFinal)
    try f.drafts.save(staleDraft)

    let promoted = try DraftRecovery.promoteOrphans(
        from: f.drafts,
        into: f.sessions,
        recoveredPrefix: "[復元] "
    )
    #expect(promoted == 0)
    // Stale draft removed; polished final untouched.
    #expect(try f.drafts.list().isEmpty)
    let kept = try #require(try f.sessions.load(id: id))
    #expect(kept.title == "2026-05-27 重要なミーティング")
    #expect(kept.transcript.count == 2)
}

@Test func recoveryDoesNotDoublePrefixOnRecursiveCrash() throws {
    // Defensive: if the app crashed AGAIN after the first recovery saved
    // the session with the prefix but before the previous launch had a
    // chance to do anything else, the user might somehow re-enter the
    // recovery codepath. Don't pile on prefixes like
    // "[復元] [復元] [復元] 録音中".
    let f = StoresFixture()
    defer { f.cleanup() }
    let id = UUID()
    let prefix = "[復元] "
    let draft = Session(
        id: id,
        title: prefix + "録音中（自動保存）",
        startedAt: .now
    )
    try f.drafts.save(draft)
    _ = try DraftRecovery.promoteOrphans(
        from: f.drafts,
        into: f.sessions,
        recoveredPrefix: prefix
    )
    let recovered = try #require(try f.sessions.load(id: id))
    #expect(recovered.title == "[復元] 録音中（自動保存）")
}

@Test func recoveryHandlesMultipleOrphansIndependently() throws {
    let f = StoresFixture()
    defer { f.cleanup() }
    let id1 = UUID()
    let id2 = UUID()
    try f.drafts.save(Session(id: id1, title: "draft 1", startedAt: Date(timeIntervalSince1970: 1_000)))
    try f.drafts.save(Session(id: id2, title: "draft 2", startedAt: Date(timeIntervalSince1970: 2_000)))
    let promoted = try DraftRecovery.promoteOrphans(
        from: f.drafts,
        into: f.sessions,
        recoveredPrefix: "[復元] "
    )
    #expect(promoted == 2)
    let titles = try f.sessions.list().map(\.title).sorted()
    #expect(titles == ["[復元] draft 1", "[復元] draft 2"])
}

@Test func recoveryPreservesExistingEndedAt() throws {
    // If the app crashed at Pause (which calls persistDraft and sets
    // endedAt = nil), endedAt remains nil and recovery should set it to
    // `now`. But if some other code path saved the draft with endedAt
    // already populated, leave it alone.
    let f = StoresFixture()
    defer { f.cleanup() }
    let id = UUID()
    let realEndedAt = Date(timeIntervalSince1970: 5_000)
    try f.drafts.save(Session(
        id: id,
        title: "preexisting end",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: realEndedAt
    ))
    _ = try DraftRecovery.promoteOrphans(
        from: f.drafts,
        into: f.sessions,
        recoveredPrefix: "[復元] ",
        now: Date(timeIntervalSince1970: 9_999_999)
    )
    let recovered = try #require(try f.sessions.load(id: id))
    #expect(recovered.endedAt == realEndedAt)
}
