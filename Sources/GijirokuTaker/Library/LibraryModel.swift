import Foundation
import SwiftUI
import GijirokuCore

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
    @Published var selection: LibrarySelection = .live
    /// When non-nil, new recordings are filed under this project.
    @Published var activeProjectID: UUID?

    let projectStore: FileProjectStore
    let sessionStore: FileSessionStore

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

    func loadSession(id: UUID) -> Session? {
        try? sessionStore.load(id: id)
    }

    func createProject(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? "新規プロジェクト" : trimmed)
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
        try? sessionStore.delete(id: row.id)
        if case .session(let id) = selection, id == row.id {
            selection = .live
        }
        reload()
    }

    func moveSession(_ row: SessionSummaryRow, to projectID: UUID?) {
        guard var session = loadSession(id: row.id) else { return }
        session.projectId = projectID
        try? sessionStore.save(session)
        reload()
    }
}
