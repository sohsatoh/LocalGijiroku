import Foundation

public struct MeetingEvent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A topic raised or suggested for discussion (not yet a decision /
        /// action). Surfaced above Actions & Decisions in the UI so the user
        /// can see what threads the meeting is opening up.
        case topic
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

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        owner: String? = nil,
        dueDate: String? = nil,
        detectedAt: Date = .now,
        resolved: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.detectedAt = detectedAt
        self.resolved = resolved
    }

    /// Custom decoder so MeetingEvent JSON saved before `resolved` existed
    /// still loads cleanly — missing field defaults to false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.text = try c.decode(String.self, forKey: .text)
        self.owner = try? c.decode(String.self, forKey: .owner)
        self.dueDate = try? c.decode(String.self, forKey: .dueDate)
        self.detectedAt = try c.decode(Date.self, forKey: .detectedAt)
        self.resolved = (try? c.decode(Bool.self, forKey: .resolved)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, owner, dueDate, detectedAt, resolved
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
                                "enum": ["topic", "question", "decision", "action"],
                            ],
                            "text": ["type": "string"],
                            "owner": ["type": ["string", "null"]],
                            "due": ["type": ["string", "null"]],
                            "resolved": ["type": "boolean"],
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

    public func extract(from segments: [TranscriptSegment]) async throws -> [MeetingEvent] {
        guard !segments.isEmpty else { return [] }
        let transcript = TranscriptFormatting.toPromptLines(segments)
        let messages = EventPrompt.extract(transcript: transcript, style: config.style)
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
            guard let kind = MeetingEvent.Kind(rawValue: dto.kind.lowercased()) else { return nil }
            return MeetingEvent(
                kind: kind,
                text: dto.text,
                owner: (dto.owner?.isEmpty == false) ? dto.owner : nil,
                dueDate: (dto.due?.isEmpty == false) ? dto.due : nil,
                resolved: dto.resolved
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
    static func extract(transcript: String, style: SummaryStyle = .builtin) -> [LLMMessage] {
        let extra = style.extraEventInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraEventInstructions)"
        let system = """
        You scan meeting transcript fragments and extract structured events.
        Output JSON only, no prose, no markdown fences.

        REQUIRED top-level shape — never omit the outer envelope, never return
        a bare event object, never return a bare array:
        {"events":[{"kind":"topic"|"question"|"decision"|"action","text":string,"owner":string?,"due":string?,"resolved":boolean}]}

        Kind definitions — be strict, do not guess:
        - topic: a discussion subject newly raised that has NOT yet become a
          decision or action. e.g. "pricing strategy is something to think
          about", "we should talk about onboarding".
        - question: an explicit unresolved question someone asked
          (often ends with "?"), still open at the end of this fragment.
        - decision: an explicit settled conclusion the group agreed on
          (signaled by "let's go with X", "we decided to X", "OK we'll do X").
          Tentative discussion does NOT count.
        - action: a concrete task with a deliverable AND, when stated, an
          owner / due. e.g. "Alice will draft the proposal by Friday".
          Vague aspirations like "we should think about X" are topic, not action.

        Quality rules:
        - Only include events EXPLICITLY stated in the transcript fragment.
          Do not infer, do not speculate.
        - Do NOT duplicate. If a topic / decision was already raised earlier
          in this fragment, list it only once.
        - text MUST be concise (≤ 30 words) and self-contained.
        - Transcript lines look like `[SpeakerLabel] ...` — when a speaker
          is mentioned alongside a decision / action / question, attribute
          it with `owner: "<speaker>"` for actions. Don't fabricate owners.
        - resolved: set to true when a question got an answer in the same
          fragment, or a topic / action was clearly closed off ("これは
          見送りで", "じゃあやめます", "解決しました" etc.). Default false.
          Decisions are reported as resolved=true when restated/confirmed.
        - Use the same language as the transcript.
        - Even with a single event, wrap it: {"events":[ {…} ]}.
        - If nothing qualifies, return {"events":[]}.\(extra)

        Examples:
        Transcript: `[A] じゃあ提案書を来週金曜までにまとめて`
        Output: {"events":[{"kind":"action","text":"提案書をまとめる","owner":"A","due":"来週金曜"}]}

        Transcript: `[Speaker_1] 価格設定をどう考えるかは今後の課題ですね`
        Output: {"events":[{"kind":"topic","text":"価格設定の方針検討"}]}

        Transcript: `[B] じゃあプランBで行きます`
        Output: {"events":[{"kind":"decision","text":"プランBを採用"}]}

        Transcript: `[A] 競合分析はいつまでに必要ですか?`
        Output: {"events":[{"kind":"question","text":"競合分析の期限"}]}
        """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: transcript),
        ]
    }
}
