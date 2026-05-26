import Foundation

public struct Project: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var note: String?
    /// Project-wide override for the LLM summary style. Applied on top of the
    /// user-level default and below any session-level override.
    public var summaryStyle: SummaryStyle?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        note: String? = nil,
        summaryStyle: SummaryStyle? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.note = note
        self.summaryStyle = summaryStyle
    }
}

public protocol ProjectStore: Sendable {
    func save(_ project: Project) throws
    func load(id: UUID) throws -> Project?
    func list() throws -> [Project]
    func delete(id: UUID) throws
}

public struct FileProjectStore: ProjectStore {
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

    public func save(_ project: Project) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(project.id.uuidString).json")
        let data = try Self.makeEncoder().encode(project)
        try data.write(to: url, options: .atomic)
    }

    public func load(id: UUID) throws -> Project? {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(Project.self, from: data)
    }

    public func list() throws -> [Project] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var projects: [Project] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let project = try? Self.makeDecoder().decode(Project.self, from: data) {
                projects.append(project)
            }
        }
        return projects.sorted(by: { $0.createdAt > $1.createdAt })
    }

    public func delete(id: UUID) throws {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
