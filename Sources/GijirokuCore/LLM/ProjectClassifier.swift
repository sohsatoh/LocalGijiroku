import Foundation

/// Picks the best-matching existing project for a freshly-recorded session.
///
/// The classifier is intentionally conservative: it returns `nil` whenever the
/// LLM expresses any doubt, the candidates are empty, or the returned name
/// doesn't exactly match a candidate. The contract is "only existing
/// projects" — never invent a new one.
public actor ProjectClassifier {
    /// Lightweight projection of `Project` so this type can stay in
    /// `GijirokuCore` without forcing a Project import on every caller.
    public struct Candidate: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let note: String?

        public init(id: UUID, name: String, note: String? = nil) {
            self.id = id
            self.name = name
            self.note = note
        }
    }

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

    public init(client: LLMClient, config: Config = .init()) {
        self.client = client
        self.config = config
    }

    /// Asks the LLM to pick the best-fitting project. Returns the matched
    /// project's UUID, or `nil` if no candidate fits (or if any failure
    /// occurs — the caller should treat the session as unfiled in that case).
    public func classify(
        summary: CumulativeSummary,
        title: String?,
        candidates: [Candidate]
    ) async throws -> UUID? {
        guard !candidates.isEmpty else { return nil }
        guard !summary.sections.isEmpty else { return nil }

        let messages = ProjectClassifierPrompt.build(
            summary: summary,
            title: title,
            candidates: candidates,
            language: config.language
        )
        // 120 tokens is plenty for `{"projectName":"...", "reason":"..."}`;
        // a reasoning halo on small models can wander, so leave a little
        // headroom beyond just the JSON body.
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 200
        )
        do {
            let chosen = try Self.parse(response: response)
            return Self.match(name: chosen, against: candidates)
        } catch {
            fputs("[ProjectClassifier] parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[ProjectClassifier] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    static let responseFormat: LLMResponseFormat = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "projectName": ["type": "string"],
                "reason": ["type": "string"],
            ],
            "required": ["projectName"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: schema) {
            return .jsonSchema(data)
        }
        return .json
    }()

    /// Extracts the chosen `projectName` value from the LLM response.
    /// Returns the raw string ("none" / empty / a candidate name); the caller
    /// is responsible for matching it back against the candidate list.
    static func parse(response: String) throws -> String {
        if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMParseError.emptyResponse
        }
        guard let jsonString = SummaryEngine.firstBalancedJSONValue(in: response) else {
            throw LLMParseError.noJSONObject(rawSnippet: LLMParseError.snippet(of: response))
        }
        guard let root = try? JSONSerialization.jsonObject(
            with: Data(jsonString.utf8),
            options: [.fragmentsAllowed]
        ) else {
            throw LLMParseError.jsonDecodeFailed(
                reason: "not valid JSON",
                rawSnippet: LLMParseError.snippet(of: jsonString)
            )
        }
        guard let dict = root as? [String: Any] else {
            throw LLMParseError.jsonDecodeFailed(
                reason: "top-level value was not an object",
                rawSnippet: LLMParseError.snippet(of: jsonString)
            )
        }
        // Tolerate a couple of alternate field names small models like to invent.
        for key in ["projectName", "project_name", "project", "name"] {
            if let v = dict[key] as? String {
                return v
            }
        }
        return ""
    }

    /// Exact-match (case-insensitive, whitespace-normalized) the chosen name
    /// against the candidate list. Returns the candidate's id, or `nil` if
    /// the name is "none" / empty / doesn't correspond to any candidate.
    static func match(name raw: String, against candidates: [Candidate]) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.lowercased() == "none" { return nil }
        let normalized = normalize(trimmed)
        return candidates.first(where: { normalize($0.name) == normalized })?.id
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum ProjectClassifierPrompt {
    static func build(
        summary: CumulativeSummary,
        title: String?,
        candidates: [ProjectClassifier.Candidate],
        language: String
    ) -> [LLMMessage] {
        let langHint = language == "auto" ? "the language of the summary" : language
        // Render candidates as `- "<name>"<: note>` so the model can quote
        // the name back verbatim. Notes are clipped so a verbose project
        // description doesn't dominate the prompt.
        let candidateLines = candidates.map { c -> String in
            let noteSuffix: String
            if let n = c.note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                let clipped = n.count > 200 ? String(n.prefix(200)) + "…" : n
                noteSuffix = ": \(clipped)"
            } else {
                noteSuffix = ""
            }
            return "- \"\(c.name)\"\(noteSuffix)"
        }.joined(separator: "\n")

        let summaryJSON = (try? String(data: JSONEncoder().encode(summary), encoding: .utf8)) ?? "{}"
        let titleLine = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : "## Generated title\n\($0)\n\n" } ?? ""

        let system = """
        You classify a meeting recording into one of a set of EXISTING projects.

        You will receive:
        - A cumulative summary of the meeting as JSON.
        - Optionally, a short generated title.
        - A list of existing projects (one per line), each given as
          `- "<project name>": <optional note>`.

        Pick at most ONE project that best matches the meeting's subject.
        Rules — read carefully:
        - You MUST choose either an exact, verbatim project name from the list
          OR the literal string `none`.
        - Do NOT invent new projects. Do NOT modify, translate, or paraphrase
          the project name. Copy it back exactly as it appears between the
          double quotes.
        - If multiple projects could fit, pick the single best match.
        - If no project is a clear match, return `none`. Prefer `none` over
          guessing.
        - Output JSON only, no prose, no markdown fences. Required shape:
          {"projectName": "<exact name from list or \"none\">", "reason": "<short \(langHint)>"}
        """

        let user = """
        ## Existing projects
        \(candidateLines.isEmpty ? "(no projects)" : candidateLines)

        \(titleLine)## Meeting summary (JSON)
        \(summaryJSON)
        """

        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }
}
