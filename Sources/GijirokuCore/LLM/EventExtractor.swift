import Foundation

public struct MeetingEvent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// AI-generated agenda proposal. Surfaced when the assistant judges
        /// that an important angle hasn't been discussed yet, given the
        /// running summary and open items. Distinct from question /
        /// decision / action — those are extracted from what was actually
        /// said, this one is proposed BY the assistant.
        case agendaSuggestion
        case question
        case decision
        case action
    }

    public let id: UUID
    public let kind: Kind
    public let text: String
    public let owner: String?
    public let dueDate: String?
    public let detectedAt: Date
    /// True when the LLM has determined the event was resolved later in
    /// the conversation. UI renders these with a strikethrough so the
    /// reader can see "this was asked / proposed but is now closed" —
    /// we never silently drop events, we surface their state instead.
    public let resolved: Bool
    /// One-line summary of HOW the event was resolved (the answer to a
    /// question, the conclusion of a topic, the outcome of an action).
    /// Only meaningful when `resolved` is true; nil otherwise.
    public let resolution: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        owner: String? = nil,
        dueDate: String? = nil,
        detectedAt: Date = .now,
        resolved: Bool = false,
        resolution: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.detectedAt = detectedAt
        self.resolved = resolved
        self.resolution = resolution
    }

    /// Custom decoder so MeetingEvent JSON saved before `resolved` /
    /// `resolution` existed still loads cleanly — missing fields default
    /// to false / nil. Also maps the legacy `topic` rawValue to
    /// `agendaSuggestion` so sessions recorded before the rename keep
    /// rendering their proposed-topic events.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        let rawKind = try c.decode(String.self, forKey: .kind)
        guard let kind = MeetingEvent.kind(fromRawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown MeetingEvent kind: \(rawKind)"
            )
        }
        self.kind = kind
        self.text = try c.decode(String.self, forKey: .text)
        self.owner = try? c.decode(String.self, forKey: .owner)
        self.dueDate = try? c.decode(String.self, forKey: .dueDate)
        self.detectedAt = try c.decode(Date.self, forKey: .detectedAt)
        self.resolved = (try? c.decode(Bool.self, forKey: .resolved)) ?? false
        self.resolution = try? c.decode(String.self, forKey: .resolution)
    }

    /// Resolve a rawValue to a `Kind`, honoring the historical `topic`
    /// alias. Used by both the persistence decoder and the LLM-response
    /// coercer so the two paths agree on what counts as the new
    /// agenda-suggestion bucket.
    public static func kind(fromRawValue raw: String) -> Kind? {
        let lower = raw.lowercased()
        if lower == "topic" { return .agendaSuggestion }
        return Kind(rawValue: lower)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, owner, dueDate, detectedAt, resolved, resolution
    }
}

public actor EventExtractor {
    public struct Config: Sendable {
        public let model: String
        public let style: SummaryStyle
        public init(model: String = "qwen2.5:7b", style: SummaryStyle = .builtin) {
            self.model = model
            self.style = style
        }
    }

    private let client: LLMClient
    private let config: Config

    public init(client: LLMClient, config: Config = .init()) {
        self.client = client
        self.config = config
    }

    /// JSON Schema that pins Ollama (0.5+) to exactly the envelope our parser
    /// expects. MLX falls back to prompt-only — schema bytes are unused there.
    /// `topic` is intentionally absent: agenda proposals come from the
    /// dedicated `AgendaSuggester` actor now, not from transcript scanning.
    static let responseFormat: LLMResponseFormat = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "events": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": [
                                "type": "string",
                                "enum": ["question", "decision", "action"],
                            ],
                            "text": ["type": "string"],
                            "owner": ["type": ["string", "null"]],
                            "due": ["type": ["string", "null"]],
                            "resolved": ["type": "boolean"],
                            "resolution": ["type": ["string", "null"]],
                        ],
                        "required": ["kind", "text"],
                    ],
                ],
            ],
            "required": ["events"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: schema) {
            return .jsonSchema(data)
        }
        return .json
    }()

    /// Extract new events from `segments`, and also let the LLM mark items in
    /// `openEvents` as resolved when the new fragment contains an answer /
    /// outcome. Open items the LLM re-emits with `resolved: true` get folded
    /// into the existing list by `EventMerger` (which keys on kind + text
    /// prefix). Open items the LLM doesn't re-emit stay open as-is.
    public func extract(
        from segments: [TranscriptSegment],
        openEvents: [MeetingEvent] = []
    ) async throws -> [MeetingEvent] {
        guard !segments.isEmpty else { return [] }
        let transcript = TranscriptFormatting.toPromptLines(segments)
        let messages = EventPrompt.extract(
            transcript: transcript,
            openEvents: openEvents,
            style: config.style
        )
        // 1200 tokens fits ~10-15 events with owner/due strings comfortably.
        // Each event is short JSON (~50-80 tokens); even noisy meetings rarely
        // exceed this in one delta turn.
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 1200
        )
        do {
            return try Self.parse(response: response)
        } catch {
            fputs("[EventExtractor] parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[EventExtractor] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    static func parse(response: String) throws -> [MeetingEvent] {
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
        return JSONCoercer.coerceEvents(root).compactMap { dto in
            // Legacy "topic" rawValue maps to .agendaSuggestion via the
            // shared helper so the persistence path and the live LLM
            // response path don't disagree about what an old kind means.
            // A small model that still drifts back to emitting "topic"
            // for a proposal lands in the AI-suggestion bucket — close
            // enough to its actual semantic that we'd rather show it than
            // drop it.
            guard let kind = MeetingEvent.kind(fromRawValue: dto.kind) else { return nil }
            return MeetingEvent(
                kind: kind,
                text: dto.text,
                owner: (dto.owner?.isEmpty == false) ? dto.owner : nil,
                dueDate: (dto.due?.isEmpty == false) ? dto.due : nil,
                resolved: dto.resolved,
                resolution: (dto.resolution?.isEmpty == false) ? dto.resolution : nil
            )
        }
    }

    /// Walks the response looking for the first balanced `[...]` array,
    /// applying the same string-escape awareness as
    /// `SummaryEngine.firstBalancedJSONObject` so brackets inside strings
    /// don't throw off the depth count.
    static func firstBalancedJSONArray(in s: String) -> String? {
        let stripped = SummaryEngine.stripThinkBlocks(s)
        let chars = Array(stripped)
        guard let start = chars.firstIndex(of: "[") else { return nil }
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
            switch c {
            case "\"": inString = true
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i])
                }
            default: break
            }
        }
        return nil
    }
}

enum EventPrompt {
    static func extract(
        transcript: String,
        openEvents: [MeetingEvent] = [],
        style: SummaryStyle = .builtin
    ) -> [LLMMessage] {
        let extra = style.extraEventInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraEventInstructions)"
        let system = """
        You scan meeting transcript fragments and extract structured events
        modelled on Notion AI Meeting Notes' Action Items / Decisions /
        Open Questions. Output JSON only, no prose, no markdown fences.

        REQUIRED top-level shape — never omit the outer envelope, never return
        a bare event object, never return a bare array:
        {"events":[{"kind":"question"|"decision"|"action","text":string,"owner":string?,"due":string?,"resolved":boolean,"resolution":string?}]}

        Kind definitions — be strict, do not guess. Topics / agenda
        proposals are NOT extracted here; a separate component proposes
        agendas based on the running summary.
        - question: a specific, answerable question that is still UNRESOLVED
          at the end of this fragment (often ends with "?"). One distinct
          question per event — don't bundle.
        - decision: an EXPLICIT settled conclusion the group agreed on
          (signaled by "let's go with X", "we decided to X", "OK we'll do
          X"). Tentative leanings ("maybe X"), individual opinions, and
          partial agreement do NOT count.
        - action: a concrete task with a clear deliverable, ideally with
          an owner and/or due. "Alice will draft the proposal by Friday".
          Vague intentions ("we should think about X") are NOT actions.

        Quality rules (Notion-style granularity):
        - Atomic: each event is ONE thing. Split "Aを決め、Bも依頼した" into
          a decision and an action.
        - Specific: text must be self-contained and meaningful without the
          transcript. Bad: "提案について議論". Good: "価格改定の最終案を
          月末までに提示".
        - Only include events EXPLICITLY stated. Do not infer, do not
          speculate, do not summarize the discussion as an event.
        - Do NOT duplicate within this response.
        - text MUST be concise (≤ 30 words / 60 chars JP).
        - Transcript lines look like `[SpeakerLabel] ...`. For actions,
          attribute via `owner: "<speaker>"` when the speaker is clearly
          the assignee. Don't fabricate owners; null is fine.
        - Use the same language as the transcript.
        - Even with a single event, wrap it: {"events":[ {…} ]}.
        - If nothing qualifies, return {"events":[]}.

        Resolution detection (CRITICAL):
        The OPEN items list below contains questions / actions that were
        extracted in earlier turns and are still unresolved. If — and
        ONLY if — the new transcript fragment resolves one of them (an
        answer is given, an action is reported done, etc.), re-emit that
        item with:
          - kind: the SAME kind as the open item
          - text: copy the open item's text VERBATIM (do not paraphrase,
            do not translate — the matcher uses prefix equality)
          - resolved: true
          - resolution: ≤20-word summary of HOW it was resolved
        Examples:
          open question "競合分析の期限" + transcript "[A] 金曜までに"
            → {"kind":"question","text":"競合分析の期限","resolved":true,"resolution":"金曜まで"}
          open action "提案書をまとめる" + transcript "[B] 提案書送りました"
            → {"kind":"action","text":"提案書をまとめる","resolved":true,"resolution":"送付済み"}
        Do NOT re-emit open items that are still unresolved — leave them
        alone, they stay open automatically. Do NOT mark an item resolved
        just because the topic was mentioned again; require an actual
        answer / outcome.\(extra)

        New-event examples:
        Transcript: `[A] じゃあ提案書を来週金曜までにまとめて`
        Output: {"events":[{"kind":"action","text":"提案書をまとめる","owner":"A","due":"来週金曜"}]}

        Transcript: `[B] じゃあプランBで行きます`
        Output: {"events":[{"kind":"decision","text":"プランBを採用"}]}

        Transcript: `[A] 競合分析はいつまでに必要ですか?`
        Output: {"events":[{"kind":"question","text":"競合分析の期限"}]}
        """
        let openBlock = renderOpenEvents(openEvents)
        let user: String = openBlock.isEmpty
            ? transcript
            : """
            ## OPEN items (already extracted; only re-emit if resolved by the new fragment)
            \(openBlock)

            ## New transcript fragment
            \(transcript)
            """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }

    /// Compact, model-friendly rendering of the still-open items. We strip
    /// already-resolved entries so the prompt stays small, and we list each
    /// item as `- [kind] text (owner: X, due: Y)` — owner/due omitted when
    /// nil so the noise floor stays low. The LLM matches via verbatim text
    /// echo, so we don't include synthetic IDs.
    ///
    /// AI-generated agenda suggestions are filtered out: they live in a
    /// different prompt context (the `AgendaSuggester`) and surfacing
    /// them here would invite the extractor to mis-handle them as
    /// transcript-derived items.
    static func renderOpenEvents(_ events: [MeetingEvent]) -> String {
        let open = events.filter { !$0.resolved && $0.kind != .agendaSuggestion }
        guard !open.isEmpty else { return "" }
        return open.map { e in
            var meta: [String] = []
            if let owner = e.owner { meta.append("owner: \(owner)") }
            if let due = e.dueDate { meta.append("due: \(due)") }
            let metaSuffix = meta.isEmpty ? "" : " (\(meta.joined(separator: ", ")))"
            return "- [\(e.kind.rawValue)] \(e.text)\(metaSuffix)"
        }
        .joined(separator: "\n")
    }
}
