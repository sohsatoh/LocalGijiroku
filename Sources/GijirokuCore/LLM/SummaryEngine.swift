import Foundation
import os.log

/// One batch of new bullets that the LLM wants to add to a single section.
/// `section` may match an existing section title (append) or be new
/// (create-and-append).
public struct SummaryUpdate: Codable, Sendable, Equatable {
    public let section: String
    public let bullets: [String]

    public init(section: String, bullets: [String]) {
        self.section = section
        self.bullets = bullets
    }
}

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

    /// JSON Schema for the append-only delta call. The LLM emits only NEW
    /// bullets per section, not the full updated summary — so per-turn token
    /// cost stays roughly constant regardless of how long the meeting has
    /// been running.
    static let updatesResponseFormat: LLMResponseFormat = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "updates": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "section": ["type": "string"],
                            "bullets": [
                                "type": "array",
                                "items": ["type": "string"],
                            ],
                        ],
                        "required": ["section", "bullets"],
                    ],
                ],
            ],
            "required": ["updates"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: schema) {
            return .jsonSchema(data)
        }
        return .json
    }()

    /// Incremental, append-only summary update. Used during live recording.
    /// The LLM sees only the existing section TITLES + the new transcript
    /// fragment and returns just the bullets to add — never re-emits or
    /// rewrites existing bullets. Per-turn cost stays roughly constant so
    /// 60-minute recordings don't drown the summary loop.
    ///
    /// The full-summary pass that runs on Stop (`regenerate(transcript:)`)
    /// is what produces the polished final output; this method is only
    /// responsible for keeping the in-progress UI moving cheaply.
    public func appendDelta(newSegments: [TranscriptSegment]) async throws -> CumulativeSummary {
        guard !newSegments.isEmpty else { return current }
        fputs("[SummaryEngine] appendDelta segments=\(newSegments.count) existingSections=\(current.sections.count)\n", stderr)
        let delta = TranscriptFormatting.toPromptLines(newSegments)
        let messages = SummaryPrompt.appendDelta(
            existingSectionTitles: current.sections.map(\.title),
            transcriptDelta: delta,
            language: config.language,
            style: config.style
        )
        // 600 tokens is enough for a single turn's worth of new bullets
        // (typically 1-3 sections × 1-3 bullets each). Tight cap = fast
        // turn-around even on small local models.
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.updatesResponseFormat,
            maxTokens: 600
        )
        fputs("[SummaryEngine] appendDelta response length=\(response.count)\n", stderr)
        do {
            let updates = try Self.parseUpdates(response: response)
            current = Self.applyUpdates(updates, to: current)
            return current
        } catch {
            fputs("[SummaryEngine] appendDelta parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[SummaryEngine] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    /// Re-summarize the CURRENT in-memory summary so semantic duplicates get
    /// merged and over-dense sections get condensed. Transcript is not
    /// involved — the LLM only sees the structured summary and emits a
    /// tightened version of the same shape.
    ///
    /// Trade-off: appendDelta only sees one window at a time and relies on
    /// string-based dedup, which catches exact restatements but not
    /// semantic ones like "リリースは Q3" vs "Q3 にリリース予定". After
    /// many turns the result is a long, repetitive list. Running this pass
    /// after each appendDelta keeps the live UI readable without paying
    /// the full transcript re-summarize cost every turn.
    ///
    /// Cheap-skip when the summary has too little content to benefit from
    /// the round trip — early-meeting turns don't need consolidation.
    /// Guard against drastic shrink so a small model that hallucinates a
    /// "tldr" instead of consolidating doesn't silently delete facts.
    public func consolidate() async throws -> CumulativeSummary {
        let totalBullets = current.sections.reduce(0) { $0 + $1.bullets.count }
        guard totalBullets >= 4 else { return current }
        fputs("[SummaryEngine] consolidate sections=\(current.sections.count) bullets=\(totalBullets)\n", stderr)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summaryJSON = (try? String(data: encoder.encode(current), encoding: .utf8)) ?? "{}"
        let messages = SummaryPrompt.consolidate(
            summaryJSON: summaryJSON,
            language: config.language,
            style: config.style
        )
        // 1500 tokens is enough to fit the consolidated rewrite of any
        // summary the appendDelta path can plausibly accumulate (we cap
        // density via the bullet-limit instructions in the prompt).
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 1500
        )
        do {
            let consolidated = try Self.parse(response: response)
            let afterBullets = consolidated.sections.reduce(0) { $0 + $1.bullets.count }
            // Drastic-shrink guard: if the LLM "consolidated" by deleting
            // more than half the bullets, treat it as info loss rather
            // than condensation and keep the original. The threshold is
            // intentionally lenient — real consolidation often does drop
            // 20–30 %, but losing 50 %+ in one pass is suspicious.
            if afterBullets * 2 < totalBullets {
                fputs("[SummaryEngine] consolidate shrank too much (\(totalBullets) → \(afterBullets)); keeping pre-consolidate summary\n", stderr)
                return current
            }
            current = consolidated
            return consolidated
        } catch {
            // Same fallback shape as appendDelta: parse failure surfaces
            // up, but `current` was already updated by the caller's
            // appendDelta, so the recording loop keeps moving.
            fputs("[SummaryEngine] consolidate parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[SummaryEngine] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    /// Fresh full-pass summary over the entire transcript. Resets internal
    /// state, then asks the LLM for a complete structured summary in one
    /// shot. Used:
    ///   - automatically on Stop, so the saved summary is the high-quality
    ///     one-shot version rather than the accumulation of cheap deltas;
    ///   - by the user-initiated "Re-summarize" button on saved sessions
    ///     (LibraryModel.regenerateSummary).
    public func regenerate(transcript: [TranscriptSegment]) async throws -> CumulativeSummary {
        current = CumulativeSummary()
        guard !transcript.isEmpty else { return current }
        fputs("[SummaryEngine] regenerate segments=\(transcript.count)\n", stderr)
        let body = TranscriptFormatting.toPromptLines(transcript)
        let messages = SummaryPrompt.fullPass(
            transcript: body,
            language: config.language,
            style: config.style
        )
        // 2000 tokens fits a polished full summary (8 sections × 5 bullets)
        // for an hour-long meeting. Capped to keep the Stop-to-save wait
        // bounded; truncation surfaces as a parse error which the caller
        // handles by retaining the in-progress summary.
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 2000
        )
        do {
            let parsed = try Self.parse(response: response)
            current = parsed
            return parsed
        } catch {
            fputs("[SummaryEngine] regenerate parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[SummaryEngine] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    /// Apply an append-only update batch to a summary. For each update:
    ///   - if a section with the same title already exists, append its
    ///     bullets (running the dedup pass to drop exact repeats);
    ///   - otherwise insert as a new section at the end.
    /// Cross-section dedup runs over the resulting summary too, so a small
    /// model that mistakenly puts the same point under two headings only
    /// shows it once.
    static func applyUpdates(_ updates: [SummaryUpdate], to existing: CumulativeSummary) -> CumulativeSummary {
        var sections = existing.sections
        for update in updates {
            let title = update.section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !update.bullets.isEmpty else { continue }
            if let idx = sections.firstIndex(where: { $0.title == title }) {
                sections[idx].bullets.append(contentsOf: update.bullets)
            } else {
                sections.append(.init(title: title, bullets: update.bullets))
            }
        }
        // Apply the same dedup pass `parse` uses, so an LLM that re-mentions
        // a bullet under a different section across turns doesn't pollute
        // the summary.
        let dtos = sections.map { JSONCoercer.SectionDTO(title: $0.title, bullets: $0.bullets) }
        let cleaned = dedupedSections(dtos)
        return CumulativeSummary(
            sections: cleaned.map { .init(title: $0.title, bullets: $0.bullets) },
            lastUpdated: .now
        )
    }

    /// Parse a `{"updates":[{"section":..., "bullets":[...]}, ...]}` response
    /// into `[SummaryUpdate]`. Tolerant of the same JSON quirks the section
    /// parser handles (markdown fences, prose padding, `<think>` blocks).
    static func parseUpdates(response: String) throws -> [SummaryUpdate] {
        if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMParseError.emptyResponse
        }
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
        return JSONCoercer.coerceUpdates(root)
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
    /// Prompt for the append-only `appendDelta` call. We only send section
    /// TITLES (not bullets) so the prompt size stays roughly constant over
    /// the lifetime of a long meeting. The LLM decides which existing
    /// section a new point extends, or creates a new section, and emits
    /// only the new bullets to add.
    static func appendDelta(
        existingSectionTitles: [String],
        transcriptDelta: String,
        language: String,
        style: SummaryStyle = .builtin
    ) -> [LLMMessage] {
        let langHint = language == "auto" ? "the dominant language of the transcript" : language
        let bulletLimit = style.maxBulletWords > 0 ? style.maxBulletWords : 14
        let sectionCap = style.maxSections > 0
            ? "\n- Do NOT exceed \(style.maxSections) total sections — when at the cap, extend an existing section instead of creating a new one."
            : ""
        let extra = style.extraSummaryInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraSummaryInstructions)"
        let titlesBlock = existingSectionTitles.isEmpty
            ? "(no sections yet — every update will create a new section.)"
            : existingSectionTitles.map { "- \($0)" }.joined(separator: "\n")
        let system = """
        You are a meeting note-taker modelled on Notion AI Meeting Notes.
        You receive the existing summary's section titles and a new
        transcript fragment, and you emit ONLY the new bullets to add.
        Output JSON only, no prose, no markdown fences.

        REQUIRED top-level shape:
        {"updates":[{"section":string,"bullets":[string]}]}

        For each substantive new point in the transcript fragment:
        - If it belongs to an existing section, set `section` to that
          section's title VERBATIM (the matcher uses string equality).
        - Otherwise set `section` to a NEW topic-specific title (≤20
          chars / Japanese) and the bullets that should appear under it.
        Multiple updates may share the same `section` — they'll be
        appended in order.

        Hard rules (CRITICAL):
        - Do NOT restate, rephrase, or include any bullet that's already
          summarized. You only see titles, not existing bullets, so be
          conservative — only emit bullets when the transcript fragment
          adds genuinely NEW information.
        - Do NOT include content that should live in the Action Items /
          Decisions / Open Questions / Suggested Topics panels (those are
          extracted separately).
        - Do NOT emit `updates` entries for filler / small talk / greetings.
        - If the fragment has no substantive new content, return
          {"updates":[]}.

        Bullet quality (Notion-style granularity):
        - Atomic: one fact / point per bullet.
        - Specific & self-contained: meaningful even read in isolation.
        - Substance over recap: capture the WHY / position / trade-off
          rather than restating surface phrasing.
        - Max \(bulletLimit) words per bullet.\(sectionCap)
        - Transcript lines look like `[SpeakerLabel] ...`. When a specific
          speaker's perspective is the substance of a bullet, prefix the
          bullet with `[SpeakerLabel] ` so the reader can attribute it.

        - Write in \(langHint).\(extra)
        """
        let user = """
        ## Existing section titles (in order)
        \(titlesBlock)

        ## New transcript fragment
        \(transcriptDelta)
        """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }

    /// Prompt for the `consolidate` call. The LLM sees ONLY the current
    /// summary (not the transcript) and produces a tighter version of the
    /// same shape — semantic duplicates merged, closely related bullets
    /// combined, redundancy across sections dropped. Keeps the live UI
    /// readable as appendDelta accumulates over a long meeting.
    static func consolidate(
        summaryJSON: String,
        language: String,
        style: SummaryStyle = .builtin
    ) -> [LLMMessage] {
        let langHint = language == "auto" ? "the dominant language of the summary" : language
        let bulletLimit = style.maxBulletWords > 0 ? style.maxBulletWords : 14
        let sectionCap = style.maxSections > 0
            ? "\n- Use at most \(style.maxSections) sections total. Merge if necessary."
            : ""
        let extra = style.extraSummaryInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraSummaryInstructions)"
        let system = """
        You are tightening an in-progress meeting summary. The input is
        the structured summary so far (no transcript). Output JSON only,
        no prose, no markdown fences.

        REQUIRED top-level shape:
        {"sections":[{"title":string,"bullets":[string]}]}

        Your job is consolidation, NOT re-extraction:
        - Merge bullets that say the same thing in different words into
          ONE concise bullet (e.g. "リリースは Q3" + "Q3 にリリース予定"
          → "リリースは Q3").
        - Combine closely related bullets within the same section into a
          single more concise bullet when it reads more clearly.
        - Drop redundancy ACROSS sections too — a point should appear in
          exactly one place.
        - Empty sections get dropped.

        HARD constraints:
        - PRESERVE ALL distinct factual information. When in doubt, leave
          two bullets separate. Losing facts is worse than redundancy.
        - DO NOT invent new content. You only see the summary, not the
          transcript — any new bullet you produce must be derivable from
          the bullets you were given.
        - Preserve section order from the input. Don't reshuffle unless
          you're merging two sections together.
        - Preserve `[SpeakerLabel] ` prefixes on bullets where present.

        Style rules:
        - Max \(bulletLimit) words per bullet.\(sectionCap)
        - Even with a single section, wrap it: {"sections":[ {…} ]}.
        - Write in \(langHint).\(extra)
        """
        let user = """
        ## Current summary
        \(summaryJSON)
        """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }

    /// Prompt for the full-pass `regenerate` call. Sends the entire
    /// transcript and asks for a complete structured summary in one shot.
    /// Used on Stop (for the saved final output) and by the user-initiated
    /// re-summarize button.
    static func fullPass(transcript: String, language: String, style: SummaryStyle = .builtin) -> [LLMMessage] {
        let langHint = language == "auto" ? "the dominant language of the transcript" : language
        let bulletLimit = style.maxBulletWords > 0 ? style.maxBulletWords : 14
        let sectionCap = style.maxSections > 0
            ? "\n- Use at most \(style.maxSections) sections total. Merge / reorganize if you exceed the cap."
            : ""
        let extra = style.extraSummaryInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraSummaryInstructions)"
        let system = """
        You are a meeting note-taker modelled on Notion AI Meeting Notes.
        You are given the FULL transcript of a meeting that just ended.
        Produce a polished structured summary. Output JSON only, no prose,
        no markdown fences.

        REQUIRED top-level shape:
        {"sections":[{"title":string,"bullets":[string]}]}

        Section structure (Notion-style):
        - Organize bullets under topical sections reflecting what was
          actually discussed (e.g. "プロジェクトX 進捗", "採用方針",
          "技術選定の議論"). Avoid generic catch-alls like "その他" or
          "全体" unless absolutely necessary.
        - DO NOT create sections that duplicate the Action Items /
          Decisions / Open Questions / Suggested Topics panels — those
          live elsewhere. The summary is the DISCUSSION, not the
          extracted to-dos.

        Bullet quality (Notion-style granularity):
        - Atomic: one fact / point per bullet.
        - Specific & self-contained: meaningful even read in isolation.
        - Substance over recap: capture the WHY / context / trade-offs.
        - Skip small talk, greetings, and filler.
        - Skip restating content that should live in Decisions / Actions
          / Questions / Topics.

        Style rules:
        - Max \(bulletLimit) words per bullet.
        - Order sections roughly in the order they appeared in the
          discussion.\(sectionCap)
        - Transcript lines look like `[SpeakerLabel] ...`. When a specific
          speaker's perspective is the substance of a bullet, prefix the
          bullet with `[SpeakerLabel] ` so the reader can attribute it.
        - Even with a single section, wrap it: {"sections":[ {…} ]}.
        - Write in \(langHint).\(extra)
        """
        let user = """
        ## Full transcript
        \(transcript)
        """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }

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
        You are a meeting note-taker modelled on Notion AI Meeting Notes.
        You receive the current cumulative summary as JSON and new
        transcript segments since the last update. Output JSON only, with
        no prose and no markdown fences.

        REQUIRED top-level shape — never omit the envelope, never return a
        bare section object, never return a bare array:
        {"sections":[{"title":string,"bullets":[string]}]}

        Section structure (Notion-style):
        - Organize bullets under topical sections that reflect what was
          ACTUALLY discussed (e.g. "プロジェクトX 進捗", "採用方針",
          "技術選定の議論"). Avoid generic catch-alls like "その他" or
          "全体" unless absolutely necessary.
        - DO NOT create sections that duplicate the Action Items /
          Decisions / Open Questions / Suggested Topics panels — those
          live elsewhere. The summary is the DISCUSSION, not the
          extracted to-dos. e.g. don't add a section titled "決定事項"
          or "アクション" or "質問".

        Bullet quality (Notion-style granularity):
        - Atomic: one fact / point per bullet. Split combined statements.
        - Specific & self-contained: a bullet should be meaningful even
          if read in isolation. Bad: "X について議論". Good: "X の
          リリース時期は来期Q3に後ろ倒し、理由は依存ライブラリ未対応".
        - Substance over recap: prefer the WHY / context / reasoning over
          surface restatement. Capture positions taken, trade-offs raised,
          and concerns voiced.
        - Skip small talk, greetings, and filler. Skip restating what's
          already explicit in a Decision / Action / Question event.

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
