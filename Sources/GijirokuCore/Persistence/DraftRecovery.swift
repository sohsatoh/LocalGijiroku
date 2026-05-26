import Foundation

/// Promote in-progress recordings (drafts) into the regular session store
/// when a previous run crashed / was killed before `persistFinalSession`
/// could write the final session itself. Pure data-flow utility so the app
/// layer just supplies the two stores and a localized prefix.
public enum DraftRecovery {
    /// Move any orphaned drafts from `drafts` to `sessions`, returning the
    /// number of drafts that were actually promoted (so the caller can show
    /// a notification when something was recovered).
    ///
    /// Behaviour:
    ///   - If a session with the draft's id already exists in `sessions`,
    ///     the previous run completed `sessionStore.save` but the
    ///     subsequent draft delete failed. Promoting would overwrite a
    ///     polished final with a stale draft; instead, just clean up the
    ///     orphan and skip.
    ///   - Otherwise, copy the draft into `sessions` with `recoveredPrefix`
    ///     prepended to its title (only when the prefix isn't already
    ///     there — defensive against re-recovery loops) and `endedAt` set
    ///     to `now` if it wasn't already populated. Then delete the draft.
    @discardableResult
    public static func promoteOrphans(
        from drafts: SessionStore,
        into sessions: SessionStore,
        recoveredPrefix: String,
        now: Date = .now
    ) throws -> Int {
        let rows = try drafts.list()
        guard !rows.isEmpty else { return 0 }
        var promoted = 0
        for row in rows {
            // Idempotency guard: don't clobber an already-saved final.
            if let existing = try? sessions.load(id: row.id), existing.id == row.id {
                try? drafts.delete(id: row.id)
                continue
            }
            guard let draft = try drafts.load(id: row.id) else { continue }
            var recovered = draft
            if !recovered.title.hasPrefix(recoveredPrefix) {
                recovered.title = recoveredPrefix + recovered.title
            }
            recovered.endedAt = recovered.endedAt ?? now
            try sessions.save(recovered)
            try drafts.delete(id: row.id)
            promoted += 1
        }
        return promoted
    }
}
