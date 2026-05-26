import Foundation

public struct SessionSummaryRow: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
}

public protocol SessionStore: Sendable {
    func save(_ session: Session) throws
    func load(id: UUID) throws -> Session?
    func list() throws -> [SessionSummaryRow]
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
                rows.append(.init(id: session.id, title: session.title, startedAt: session.startedAt))
            }
        }
        return rows.sorted(by: { $0.startedAt > $1.startedAt })
    }

    public func exportMarkdown(_ session: Session) -> String {
        var out = "# \(session.title)\n\n"
        out += "_\(ISO8601DateFormatter().string(from: session.startedAt))_\n\n"

        out += "## Summary\n\n"
        for section in session.summary.sections {
            out += "### \(section.title)\n"
            for bullet in section.bullets {
                out += "- \(bullet)\n"
            }
            out += "\n"
        }

        if !session.events.isEmpty {
            out += "## Events\n\n"
            for event in session.events {
                let owner = event.owner.map { " (@\($0))" } ?? ""
                let due = event.dueDate.map { " — due \($0)" } ?? ""
                out += "- [\(event.kind.rawValue)] \(event.text)\(owner)\(due)\n"
            }
            out += "\n"
        }

        out += "## Transcript\n\n"
        for seg in session.transcript {
            out += "- [\(seg.source.rawValue)] \(seg.text)\n"
        }
        return out
    }
}
