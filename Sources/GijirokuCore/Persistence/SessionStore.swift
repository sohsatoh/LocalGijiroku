import Foundation

public struct SessionSummaryRow: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let projectId: UUID?
    public let title: String
    public let startedAt: Date

    public init(id: UUID, projectId: UUID?, title: String, startedAt: Date) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.startedAt = startedAt
    }
}

public protocol SessionStore: Sendable {
    func save(_ session: Session) throws
    func load(id: UUID) throws -> Session?
    func list() throws -> [SessionSummaryRow]
    func list(byProjectID projectID: UUID?) throws -> [SessionSummaryRow]
    func delete(id: UUID) throws
    func exportMarkdown(_ session: Session) -> String
}

public struct FileSessionStore: SessionStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(session.id.uuidString).json")
        let data = try Self.makeEncoder().encode(session)
        try data.write(to: url, options: .atomic)
    }

    public func load(id: UUID) throws -> Session? {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(Session.self, from: data)
    }

    public func list() throws -> [SessionSummaryRow] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var rows: [SessionSummaryRow] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let session = try? Self.makeDecoder().decode(Session.self, from: data) {
                rows.append(.init(id: session.id, projectId: session.projectId, title: session.title, startedAt: session.startedAt))
            }
        }
        return rows.sorted(by: { $0.startedAt > $1.startedAt })
    }

    public func list(byProjectID projectID: UUID?) throws -> [SessionSummaryRow] {
        try list().filter { $0.projectId == projectID }
    }

    public func delete(id: UUID) throws {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func exportMarkdown(_ session: Session) -> String {
        MarkdownExporter.render(session, style: session.summaryStyle ?? .builtin)
    }
}
