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
        public let style: SummaryStyle
        public init(model: String = "qwen2.5:7b", language: String = "auto", style: SummaryStyle = .builtin) {
            self.model = model
            self.language = language
            self.style = style
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

    /// JSON Schema that constrains backends with grammar-mode (Ollama 0.5+)
    /// to emit exactly `{"sections":[{"title":..., "bullets":[...]}]}`.
    /// MLX falls back to prompt-only since the swift wrapper has no
    /// constrained-decoding hook.
    static let responseFormat: LLMResponseFormat = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "bullets": [
                                "type": "array",
                                "items": ["type": "string"],
                            ],
                        ],
                        "required": ["title", "bullets"],
                    ],
                ],
            ],
            "required": ["sections"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: schema) {
            return .jsonSchema(data)
        }
        return .json
    }()

    public func ingest(newSegments: [TranscriptSegment]) async throws -> CumulativeSummary {
        guard !newSegments.isEmpty else { return current }
        fputs("[SummaryEngine] ingest called segments=\(newSegments.count)\n", stderr)
        let delta = TranscriptFormatting.toPromptLines(newSegments)
        let messages = SummaryPrompt.update(
            existing: current,
            transcriptDelta: delta,
            language: config.language,
            style: config.style
        )
        fputs("[SummaryEngine] calling client.chat model=\(config.model) messages=\(messages.count)\n", stderr)
        // 1500 tokens is enough for ~6 sections × ~4 bullets in JP/EN —
        // matches our prompt's section cap. If the user lifts the cap via
        // SummaryStyle this may truncate; revisit then.
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 1500
        )
        fputs("[SummaryEngine] got response length=\(response.count)\n", stderr)
        do {
            let updated = try Self.parse(response: response)
            current = updated
            return updated
        } catch {
            // Surface the raw response in the log so the developer / user can
            // see exactly what the LLM emitted when parsing fails. Without
            // this, "LLMParseError error 0" is uninformative.
            fputs("[SummaryEngine] parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[SummaryEngine] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    static func parse(response: String) throws -> CumulativeSummary {
        if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMParseError.emptyResponse
        }
        // Locate the first JSON value (object or array) in the raw response
        // — small models sometimes prepend prose or recovery text.
        guard let jsonString = firstBalancedJSONValue(in: response) else {
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
        // Coerce the tree to `[SectionDTO]` regardless of envelope / key
        // names / `bullets`-as-object-array shenanigans (see JSONCoercer).
        let coerced = JSONCoercer.coerceSections(root)
        // Post-process: dedupe bullets within each section and across
        // sections. Small models sometimes re-emit the same bullet under a
        // different heading on each turn; this is the safety net for that.
        let cleaned = Self.dedupedSections(coerced)
        return CumulativeSummary(
            sections: cleaned.map { .init(title: $0.title, bullets: $0.bullets) },
            lastUpdated: .now
        )
    }

    /// Bullet dedup pass. Strategy:
    ///   - Normalize each bullet (trim, lowercase, collapse whitespace) for
    ///     comparison only — the displayed bullet keeps original casing.
    ///   - Within a section: drop later bullets whose normalized form was
    ///     already seen.
    ///   - Across sections: keep the first occurrence (in document order),
    ///     drop subsequent duplicates regardless of which section they're
    ///     in. Prevents the same point from appearing under multiple
    ///     topics when the LLM mis-attributes.
    static func dedupedSections(_ sections: [JSONCoercer.SectionDTO]) -> [JSONCoercer.SectionDTO] {
        var globalSeen = Set<String>()
        return sections.map { section in
            var localSeen = Set<String>()
            var out: [String] = []
            for bullet in section.bullets {
                let key = normalizeForDedup(bullet)
                guard !key.isEmpty else { continue }
                if globalSeen.contains(key) || localSeen.contains(key) {
                    continue
                }
                localSeen.insert(key)
                globalSeen.insert(key)
                out.append(bullet)
            }
            return JSONCoercer.SectionDTO(title: section.title, bullets: out)
        }
    }

    static func normalizeForDedup(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Normalizes a raw LLM response into a JSON object string.
    /// Handles four common patterns:
    ///   1. The response is already pure JSON.
    ///   2. The JSON is wrapped in a markdown code fence (```json ... ```).
    ///   3. The JSON is surrounded by prose ("Here is the summary: {...} Let me know if...").
    ///   4. Reasoning models (Qwen3, DeepSeek R1, etc.) emit
    ///      `<think>...</think>` chain-of-thought blocks before the answer.
    /// Throws `LLMParseError.noJSONObject` if no balanced `{ ... }` pair is found.
    static func extractJSONPayload(_ raw: String) throws -> String {
        let dethought = stripThinkBlocks(raw)
        let unfenced = stripJSONFences(dethought)
        if let extracted = firstBalancedJSONObject(in: unfenced) {
            return extracted
        }
        throw LLMParseError.noJSONObject(rawSnippet: LLMParseError.snippet(of: raw))
    }

    /// Returns the first balanced top-level JSON value (object or array) in
    /// `raw`, after stripping `<think>` blocks and code fences. Used by the
    /// parsers as the input to `JSONSerialization`/`JSONCoercer`.
    public static func firstBalancedJSONValue(in raw: String) -> String? {
        let stripped = stripJSONFences(stripThinkBlocks(raw))
        let chars = Array(stripped)
        // Locate whichever of `{` / `[` appears earlier.
        var startIdx: Int?
        var open: Character = "{"
        var close: Character = "}"
        for (i, c) in chars.enumerated() {
            if c == "{" { startIdx = i; open = "{"; close = "}"; break }
            if c == "[" { startIdx = i; open = "["; close = "]"; break }
        }
        guard let start = startIdx else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        for i in start..<chars.count {
            let c = chars[i]
            if escape { escape = false; continue }
            if inString {
                if c == "\\" { escape = true; continue }
                if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; continue }
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i])
                }
            }
        }
        return nil
    }

    /// Strips `<think>...</think>` chain-of-thought blocks emitted by
    /// reasoning models. An unclosed `<think>` is treated as "everything from
    /// here on is internal" and dropped. Public so other modules (AppModel's
    /// title sanitizer) can reuse the same parser.
    public static func stripThinkBlocks(_ s: String) -> String {
        var result = s
        while let openRange = result.range(of: "<think>", options: [.caseInsensitive]) {
            if let closeRange = result.range(
                of: "</think>",
                options: [.caseInsensitive],
                range: openRange.upperBound..<result.endIndex
            ) {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                // Open tag with no close tag: dump everything from <think> onward.
                result.removeSubrange(openRange.lowerBound..<result.endIndex)
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

public enum LLMParseError: LocalizedError, Equatable {
    /// LLM returned an empty / whitespace-only string.
    case emptyResponse
    /// The response had no balanced `{ ... }` payload after stripping
    /// reasoning blocks and markdown fences. `rawSnippet` is a short
    /// prefix of the raw response for diagnosis.
    case noJSONObject(rawSnippet: String)
    /// Found a JSON object but JSONDecoder couldn't map it to the expected
    /// schema (e.g. missing fields, wrong types).
    case jsonDecodeFailed(reason: String, rawSnippet: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "LLM returned an empty response. Try re-summarizing, or switch to a larger model."
        case .noJSONObject(let snippet):
            return "LLM did not return valid JSON. Raw snippet: \(snippet)"
        case .jsonDecodeFailed(let reason, let snippet):
            return "LLM JSON did not match the expected schema (\(reason)). Raw snippet: \(snippet)"
        }
    }

    /// Trims and truncates a raw LLM response so it can be safely embedded in
    /// an error message / log line without flooding the UI.
    public static func snippet(of raw: String, limit: Int = 200) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

enum SummaryPrompt {
    static func update(existing: CumulativeSummary, transcriptDelta: String, language: String, style: SummaryStyle = .builtin) -> [LLMMessage] {
        let existingJSON = (try? String(data: JSONEncoder().encode(existing), encoding: .utf8)) ?? "{}"
        let langHint = language == "auto" ? "the dominant language of the transcript" : language
        let bulletLimit = style.maxBulletWords > 0 ? style.maxBulletWords : 14
        let sectionCap = style.maxSections > 0
            ? "\n- Use at most \(style.maxSections) sections total. Merge or reorganize if you exceed the cap."
            : ""
        let extra = style.extraSummaryInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraSummaryInstructions)"
        let system = """
        You are a meeting note-taker. You receive the current cumulative
        summary as JSON and new transcript segments since the last update.
        Output JSON only, with no prose and no markdown fences.

        REQUIRED top-level shape — never omit the envelope, never return a
        bare section object, never return a bare array:
        {"sections":[{"title":string,"bullets":[string]}]}

        Merging rules (critical — read carefully):
        - The returned JSON is the FULL updated summary, NOT a delta.
          Always include every existing section + bullet, then merge new
          content into the appropriate section.
        - Before adding a new bullet, check if a bullet with the same
          information already exists. If yes, do NOT add a duplicate.
          Refine the wording of the existing bullet only if the new
          transcript adds genuinely new detail.
        - Before adding a new section, check if an existing section
          covers the same topic. If yes, append into it instead.
        - Bullets must NOT repeat across different sections.

        Style rules:
        - Keep each bullet concise (max \(bulletLimit) words).
        - Preserve section order; new sections go at the end.\(sectionCap)
        - Transcript lines look like `[SpeakerLabel] ...` — when a specific
          speaker's perspective / decision / position is the substance of
          the bullet, prefix the bullet with `[SpeakerLabel] ` so the reader
          can attribute it. Otherwise omit the prefix.
        - Even with a single section, wrap it: {"sections":[ {…} ]}.
        - Write in \(langHint).\(extra)
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
