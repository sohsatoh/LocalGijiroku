import SwiftUI
import GijirokuCore

/// Read-only view for a previously-saved session, mirroring the layout of the
/// live recording view (transcript / summary / events). Also exposes a
/// "re-summarize" button that re-runs the LLM over the saved transcript.
///
/// **Note**: the parent must apply `.id(session.id)` so SwiftUI recreates this
/// view when the selected session changes. Otherwise `@State` here keeps
/// holding the original session and the panes look frozen.
struct SessionDetailView: View {
    let sessionID: UUID
    @EnvironmentObject private var library: LibraryModel
    @State private var loadedSession: Session?
    @State private var lastReloadStamp: Date = .distantPast
    @State private var editingStyle: Session?

    init(session: Session) {
        self.sessionID = session.id
        _loadedSession = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            header(session: loadedSession)
            Divider()
            if let session = loadedSession {
                HSplitView {
                    TranscriptPane(segments: session.transcript)
                        .frame(minWidth: 280, idealWidth: 360)
                    SummaryPane(summary: session.summary)
                        .frame(minWidth: 280, idealWidth: 360)
                    EventPane(events: session.events)
                        .frame(minWidth: 240, idealWidth: 280)
                }
            } else {
                ContentUnavailableView(L10n.string("error.session_load_failed"), systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(loadedSession?.title ?? L10n.string("session.title_fallback"))
        .onAppear {
            // Defensive: even with the `.id(sessionID)` modifier on the parent,
            // make sure we have the latest disk state when this view appears.
            loadedSession = library.loadSession(id: sessionID)
        }
        .onChange(of: library.regeneratingSessionID) { oldValue, newValue in
            // Regeneration finished (transitioned to nil) → pull the fresh
            // session from disk.
            if oldValue != nil && newValue == nil {
                loadedSession = library.loadSession(id: sessionID)
                lastReloadStamp = .now
            }
        }
        .sheet(item: $editingStyle) { session in
            SessionStyleSheet(
                session: session,
                onSave: { updated in
                    library.updateSession(updated)
                    loadedSession = updated
                    editingStyle = nil
                },
                onCancel: { editingStyle = nil }
            )
        }
    }

    private func header(session: Session?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session?.title ?? "—")
                    .font(.headline)
                Text(timeRangeString(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRegeneratingMe {
                ProgressBadge(progress: library.regenerationProgress)
            } else if case .done = library.regenerationProgress, library.regeneratingSessionID == nil, loadedSession?.id == sessionID {
                // 完了直後の表示
                ProgressBadge(progress: library.regenerationProgress)
            }
            Text(L10n.format("session.stats_format", session?.transcript.count ?? 0, session?.events.count ?? 0))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                if let session { editingStyle = session }
            } label: {
                Label(loc: "recording.template", systemImage: "doc.text")
            }
            .disabled(session == nil)
            Button {
                Task { await library.regenerateSummary(for: sessionID) }
            } label: {
                Label(loc: "recording.regenerate_summary", systemImage: "arrow.clockwise")
            }
            .disabled(library.regeneratingSessionID != nil || (session?.transcript.isEmpty ?? true))
            .help(L10n.string("recording.regenerate_summary.help"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isRegeneratingMe: Bool {
        library.regeneratingSessionID == sessionID
    }

    private func timeRangeString(for session: Session?) -> String {
        guard let session else { return "" }
        let start = session.startedAt.formatted(date: .numeric, time: .shortened)
        if let end = session.endedAt {
            let durationSec = Int(end.timeIntervalSince(session.startedAt))
            let mins = durationSec / 60
            let secs = durationSec % 60
            return L10n.format("session.duration_format", start, mins, secs)
        }
        return start
    }
}
