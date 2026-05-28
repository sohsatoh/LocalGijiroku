import Foundation
import SwiftUI
import GijirokuCore
import GijirokuLLM

/// Selection state for the sidebar: either the live recording session or a
/// past saved session.
enum LibrarySelection: Hashable {
    case live
    case session(UUID)
}

@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    @Published var projects: [Project] = []
    @Published var allSessions: [SessionSummaryRow] = []
    /// Multi-selection. When exactly one item is selected the detail view
    /// shows it; with multiple session selections the detail shows a
    /// bulk-action view. `.live` is always exactly one item by itself.
    @Published var selection: Set<LibrarySelection> = [.live]
    /// When non-nil, new recordings are filed under this project.
    @Published var activeProjectID: UUID?
    /// Currently in-flight regeneration. Used by the UI to disable the
    /// regenerate button and render a progress indicator.
    @Published var regeneratingSessionID: UUID?
    @Published var regenerationProgress: SummaryProgress = .idle

    let projectStore: FileProjectStore
    let sessionStore: FileSessionStore

    /// True while a past-session regeneration is mid-flight. Used by the
    /// app-quit handler in the same way as `AppModel.isAnyLLMTaskInFlight`
    /// — Cmd+Q here would otherwise tear down MLX under the regenerate's
    /// active Metal command buffer and SIGABRT in `Scheduler::~Scheduler()`.
    var isAnyLLMTaskInFlight: Bool {
        regeneratingSessionID != nil || regenerationProgress.isBusy
    }

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let projectsDir = appSupport.appendingPathComponent("GijirokuTaker/Projects", isDirectory: true)
        let sessionsDir = appSupport.appendingPathComponent("GijirokuTaker/Sessions", isDirectory: true)
        self.projectStore = FileProjectStore(directory: projectsDir)
        self.sessionStore = FileSessionStore(directory: sessionsDir)
        reload()
    }

    func reload() {
        projects = (try? projectStore.list()) ?? []
        allSessions = (try? sessionStore.list()) ?? []
    }

    func sessions(in projectID: UUID?) -> [SessionSummaryRow] {
        allSessions.filter { $0.projectId == projectID }
    }

    /// The single focused selection (used to drive the detail pane).
    var singleSelection: LibrarySelection? {
        selection.count == 1 ? selection.first : nil
    }

    /// All session IDs currently selected (excluding the live sentinel).
    var selectedSessionIDs: Set<UUID> {
        Set(selection.compactMap { sel -> UUID? in
            if case .session(let id) = sel { return id }
            return nil
        })
    }

    func loadSession(id: UUID) -> Session? {
        try? sessionStore.load(id: id)
    }

    func createProject(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? L10n.string("project.untitled_name") : trimmed)
        try? projectStore.save(project)
        reload()
        return project
    }

    func renameProject(_ project: Project, to newName: String) {
        var p = project
        p.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try? projectStore.save(p)
        reload()
    }

    func updateProject(_ project: Project) {
        try? projectStore.save(project)
        reload()
    }

    func updateSession(_ session: Session) {
        try? sessionStore.save(session)
        reload()
    }

    /// Deletes a project. Sessions filed under it become unfiled instead of
    /// being deleted with it.
    func deleteProject(_ project: Project) {
        for row in sessions(in: project.id) {
            if var session = loadSession(id: row.id) {
                session.projectId = nil
                try? sessionStore.save(session)
            }
        }
        try? projectStore.delete(id: project.id)
        if activeProjectID == project.id { activeProjectID = nil }
        reload()
    }

    func deleteSession(_ row: SessionSummaryRow) {
        deleteSessions([row.id])
    }

    /// Deletes a set of sessions and prunes them from the current selection.
    /// If the selection ends up empty, falls back to `.live` so the detail
    /// pane always has something to show.
    func deleteSessions(_ ids: Set<UUID>) {
        for id in ids {
            try? sessionStore.delete(id: id)
        }
        let filtered = selection.filter { sel in
            if case .session(let sid) = sel { return !ids.contains(sid) }
            return true
        }
        selection = filtered.isEmpty ? [.live] : filtered
        reload()
    }

    func moveSession(_ row: SessionSummaryRow, to projectID: UUID?) {
        guard var session = loadSession(id: row.id) else { return }
        session.projectId = projectID
        try? sessionStore.save(session)
        reload()
    }

    /// Re-runs summary + event extraction over the transcript of an existing
    /// session and writes the result back to disk. Progress is published on
    /// `regenerationProgress`; the UI should observe it for a status line.
    func regenerateSummary(for sessionID: UUID) async {
        guard regeneratingSessionID == nil else { return }
        guard var session = loadSession(id: sessionID) else { return }
        guard !session.transcript.isEmpty else {
            regenerationProgress = .failed(message: "Transcript is empty")
            return
        }

        regeneratingSessionID = sessionID
        defer { regeneratingSessionID = nil }

        let settings = SettingsModel.shared
        let language: String = {
            switch settings.whisperLanguage {
            case "ja": return "Japanese"
            case "en": return "English"
            default: return "auto"
            }
        }()

        let llm: any LLMClient
        switch settings.llmBackend {
        case .ollama:
            let url = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
            llm = OllamaClient(baseURL: url)
        case .mlx:
            llm = MLXClient { [weak self] progress in
                guard progress.fraction < 0.99 else { return }
                Task { @MainActor in
                    self?.regenerationProgress = .modelDownloading(
                        modelID: progress.modelID,
                        fraction: progress.fraction
                    )
                }
            }
        }

        let model = settings.activeLLMModelID
        // Resolve summary style from user / project / session layers.
        let project = session.projectId.flatMap { id in
            projects.first(where: { $0.id == id })
        }
        let resolvedStyle = SummaryStyle.resolved(
            user: settings.userSummaryStyle,
            project: project?.summaryStyle,
            session: session.summaryStyle
        )
        let summaryEngine = SummaryEngine(client: llm, config: .init(model: model, language: language, style: resolvedStyle))
        let eventExtractor = EventExtractor(client: llm, config: .init(model: model, style: resolvedStyle))

        regenerationProgress = .summarizing(segmentCount: session.transcript.count)
        do {
            // Full-pass regenerate: produce a fresh summary over the entire
            // saved transcript in one shot, replacing whatever the
            // recording-time delta loop accumulated.
            let newSummary = try await summaryEngine.regenerate(transcript: session.transcript)
            session.summary = newSummary
            regenerationProgress = .extractingEvents(segmentCount: session.transcript.count)
            do {
                let newEvents = try await eventExtractor.extract(
                    from: session.transcript,
                    openEvents: session.events
                )
                // Event extraction is not authoritative deletion: the model
                // can legally return an empty or partial list even when useful
                // events already exist. Keep the current pane contents and let
                // the merger rewrite/add details from the fresh pass.
                var merged = session.events
                EventMerger().merge(newEvents, into: &merged)
                session.events = merged
            } catch {
                fputs("[GijirokuTaker] session event extraction failed (keeping existing events): \(error.localizedDescription)\n", stderr)
            }
            try sessionStore.save(session)
            reload()
            regenerationProgress = .done(
                at: .now,
                sections: session.summary.sections.count,
                events: session.events.count
            )
        } catch {
            regenerationProgress = .failed(message: error.localizedDescription)
        }
        // Drop MLX session caches now that this regeneration is done.
        // Same rationale as AppModel: each regenerate kicks two
        // distinct ChatSession buckets (regenerate prompt + EventExtractor
        // prompt), each up to several GB of KV cache. Without this they
        // pile up across successive "Re-summarize" clicks until the
        // next model switch or app quit.
        if let mlx = llm as? MLXClient {
            await mlx.flushSessionCache()
        }
    }
}
