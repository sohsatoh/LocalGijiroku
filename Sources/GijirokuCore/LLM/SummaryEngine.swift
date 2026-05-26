import Foundation
import os.log

public struct CumulativeSummary: Codable, Sendable, Equatable {
    public var sections: [Section]
    public var lastUpdated: Date

    public struct Section: Codable, Sendable, Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        public var bullets: [String]

        public init(title: String, bullets: [String]) {
            self.title = title
            self.bullets = bullets
        }
    }

    public init(sections: [Section] = [], lastUpdated: Date = .now) {
        self.sections = sections
        self.lastUpdated = lastUpdated
    }
}

public actor SummaryEngine {
    public struct Config: Sendable {
        public let model: String
        public let language: String
        public init(model: String = "qwen2.5:7b", language: String = "auto") {
            self.model = model
            self.language = language
        }
    }

    private let client: LLMClient
    private let config: Config
    private var current = CumulativeSummary()

    public init(client: LLMClient, config: Config = .init()) {
        self.client = client
        self.config = config
    }

    public func currentSummary() -> CumulativeSummary {
        current
    }

    public func reset() {
        current = CumulativeSummary()
    }

    public func ingest(newSegments: [TranscriptSegment]) async throws -> CumulativeSummary {
        guard !newSegments.isEmpty else { return current }
        fputs("[SummaryEngine] ingest called segments=\(newSegments.count)\n", stderr)
        let delta = newSegments
            .map { "[\($0.source.rawValue)] \($0.text)" }
            .joined(separator: "\n")
        let messages = SummaryPrompt.update(
            existing: current,
            transcriptDelta: delta,
            language: config.language
        )
        fputs("[SummaryEngine] calling client.chat model=\(config.model) messages=\(messages.count)\n", stderr)
        let response = try await client.chat(model: config.model, messages: messages, format: .json)
        fputs("[SummaryEngine] got response length=\(response.count)\n", stderr)
        let updated = try Self.parse(response: response)
        current = updated
        return updated
    }

    static func parse(response: String) throws -> CumulativeSummary {
        struct Wrapper: Decodable {
            let sections: [SectionDTO]
            struct SectionDTO: Decodable {
                let title: String
                let bullets: [String]
            }
        }
        let json = try extractJSONPayload(response)
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        return CumulativeSummary(
            sections: wrapper.sections.map { .init(title: $0.title, bullets: $0.bullets) },
            lastUpdated: .now
        )
    }

    /// Normalizes a raw LLM response into a JSON object string.
    /// Handles three common patterns:
    ///   1. The response is already pure JSON.
    ///   2. The JSON is wrapped in a markdown code fence (```json ... ```).
    ///   3. The JSON is surrounded by prose ("Here is the summary: {...} Let me know if...").
    /// Throws `LLMParseError.noJSONObject` if no balanced `{ ... }` pair is found.
    static func extractJSONPayload(_ raw: String) throws -> String {
        let unfenced = stripJSONFences(raw)
        if let extracted = firstBalancedJSONObject(in: unfenced) {
            return extracted
        }
        throw LLMParseError.noJSONObject
    }

    static func stripJSONFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }

    /// Returns the substring spanning the first balanced `{...}` object,
    /// respecting JSON string-escape rules so braces inside `"..."` don't
    /// affect nesting depth. Returns nil if no such object exists.
    static func firstBalancedJSONObject(in s: String) -> String? {
        let chars = Array(s)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        for i in start..<chars.count {
            let c = chars[i]
            if escape {
                escape = false
                continue
            }
            if inString {
                if c == "\\" {
                    escape = true
                    continue
                }
                if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i])
                }
            default:
                break
            }
        }
        return nil
    }
}

public enum LLMParseError: Error, Equatable {
    case noJSONObject
}

enum SummaryPrompt {
    static func update(existing: CumulativeSummary, transcriptDelta: String, language: String) -> [LLMMessage] {
        let existingJSON = (try? String(data: JSONEncoder().encode(existing), encoding: .utf8)) ?? "{}"
        let langHint = language == "auto" ? "the dominant language of the transcript" : language
        let system = """
        You are a meeting note-taker. You receive the current cumulative summary as JSON and new transcript segments since the last update.
        Output an updated summary as JSON only, with no prose and no markdown fences:
        {"sections":[{"title":string,"bullets":[string]}]}
        Rules:
        - Append bullets to the relevant existing section when the topic continues.
        - Start a new section when the topic clearly shifts.
        - Keep each bullet concise (max 14 words).
        - Preserve section order; new sections go at the end.
        - Write in \(langHint).
        """
        let user = """
        ## Current summary (JSON)
        \(existingJSON)

        ## New transcript segments
        \(transcriptDelta)
        """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }
}
