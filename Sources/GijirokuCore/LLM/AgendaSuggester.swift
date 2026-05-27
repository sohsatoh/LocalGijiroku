import Foundation

/// AI-driven counterpart to `EventExtractor`. Where the extractor lifts
/// items out of what was literally said, `AgendaSuggester` reasons over
/// the running summary, still-open events, and a small slice of the most
/// recent transcript to propose topics the meeting hasn't tackled yet
/// but probably should. Output rides on the same `MeetingEvent` shape
/// (kind = `.agendaSuggestion`) so the merger, persistence, and UI
/// pipelines stay shared.
public actor AgendaSuggester {
    public struct Config: Sendable {
        public let model: String
        public let style: SummaryStyle
        /// Maximum number of new suggestions to surface per turn. Two is
        /// the high end of useful — more reads as noise and pushes the
        /// user away from following the actual conversation.
        public let maxSuggestionsPerTurn: Int
        /// Hard cap on transcript lines fed to the model. We deliberately
        /// withhold the rest of the conversation: the running summary is
        /// the abstraction the assistant should reason over, and shipping
        /// the full transcript would defeat the cost and privacy story.
        public let recentTranscriptLineCap: Int

        public init(
            model: String = "qwen2.5:7b",
            style: SummaryStyle = .builtin,
            maxSuggestionsPerTurn: Int = 2,
            recentTranscriptLineCap: Int = 30
        ) {
            self.model = model
            self.style = style
            self.maxSuggestionsPerTurn = maxSuggestionsPerTurn
            self.recentTranscriptLineCap = recentTranscriptLineCap
        }
    }

    private let client: LLMClient
    private let config: Config

    public init(client: LLMClient, config: Config = .init()) {
        self.client = client
        self.config = config
    }

    /// Schema for Ollama 0.5+ structured output. The envelope is named
    /// `suggestions` so the model can't confuse it with the
    /// `EventExtractor` schema (`events`). `kind` is fixed and omitted
    /// from the schema — the parser always stamps `.agendaSuggestion`.
    static let responseFormat: LLMResponseFormat = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "suggestions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "rationale": ["type": ["string", "null"]],
                            "resolved": ["type": "boolean"],
                            "resolution": ["type": ["string", "null"]],
                        ],
                        "required": ["text"],
                    ],
                ],
            ],
            "required": ["suggestions"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: schema) {
            return .jsonSchema(data)
        }
        return .json
    }()

    /// Ask the model for at most `maxSuggestionsPerTurn` proposals, plus
    /// any open suggestions the recent transcript has now covered (so
    /// they can be marked resolved). The caller is responsible for
    /// merging the result into its event list via `EventMerger`.
    ///
    /// - Parameters:
    ///   - summary: the running CumulativeSummary, used as the
    ///     conversation's abstraction layer. Bullet text is sent verbatim.
    ///   - openSuggestions: previously-emitted `.agendaSuggestion` items
    ///     that haven't been marked resolved yet. The model is asked to
    ///     re-emit them with `resolved: true` if the recent transcript
    ///     shows the topic has actually been discussed.
    ///   - resolvedEvents: questions / decisions / actions already
    ///     captured by `EventExtractor`. Passed so the model can avoid
    ///     proposing things that are de facto on the agenda already.
    ///   - recentSegments: a small slice of the latest transcript only —
    ///     `recentTranscriptLineCap` lines at most. The rest of the
    ///     conversation lives in `summary`.
    public func suggest(
        summary: CumulativeSummary,
        openSuggestions: [MeetingEvent],
        recordedEvents: [MeetingEvent],
        recentSegments: [TranscriptSegment]
    ) async throws -> [MeetingEvent] {
        // Skip the LLM call entirely when the summary is still empty.
        // Suggestions need an abstraction to reason over; a one-bullet
        // transcript slice produces noise more often than insight.
        guard !summary.sections.isEmpty else { return [] }

        let recent = Array(recentSegments.suffix(config.recentTranscriptLineCap))
        let messages = AgendaPrompt.suggest(
            summary: summary,
            openSuggestions: openSuggestions,
            recordedEvents: recordedEvents,
            recentTranscript: TranscriptFormatting.toPromptLines(recent),
            maxSuggestions: config.maxSuggestionsPerTurn,
            style: config.style
        )
        // 600 tokens easily fits 2 short suggestions with rationale +
        // any resolution re-emissions. We don't need EventExtractor's
        // 1200-token budget since this turn is intentionally narrow.
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 600
        )
        do {
            return try Self.parse(response: response)
        } catch {
            fputs("[AgendaSuggester] parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[AgendaSuggester] raw (first 400 chars): \(response.prefix(400))\n", stderr)
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
        return coerceSuggestions(root).compactMap { dto in
            let text = dto.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return MeetingEvent(
                kind: .agendaSuggestion,
                text: text,
                resolved: dto.resolved,
                resolution: (dto.resolution?.isEmpty == false) ? dto.resolution : nil
            )
        }
    }

    /// Local DTO + coercion. Kept inside `AgendaSuggester` rather than
    /// added to `JSONCoercer` because the schema is unique to this actor
    /// — there's no benefit to making the shared coercer aware of it.
    private struct SuggestionDTO {
        let text: String
        let resolved: Bool
        let resolution: String?
    }

    private static func coerceSuggestions(_ root: Any) -> [SuggestionDTO] {
        var entries: [[String: Any]] = []
        if let arr = root as? [Any] {
            entries = arr.compactMap { $0 as? [String: Any] }
        } else if let obj = root as? [String: Any] {
            for key in ["suggestions", "agenda", "topics", "items"] {
                if let arr = obj[key] as? [Any] {
                    entries = arr.compactMap { $0 as? [String: Any] }
                    break
                }
            }
            if entries.isEmpty, obj["text"] != nil {
                entries = [obj]
            }
        }
        return entries.compactMap { dict -> SuggestionDTO? in
            guard let text = (dict["text"] ?? dict["topic"] ?? dict["title"]) as? String else {
                return nil
            }
            let resolved = (dict["resolved"] as? Bool)
                ?? (dict["closed"] as? Bool)
                ?? (dict["covered"] as? Bool)
                ?? false
            let resolution = (dict["resolution"] ?? dict["outcome"]) as? String
            return SuggestionDTO(text: text, resolved: resolved, resolution: resolution)
        }
    }
}

enum AgendaPrompt {
    static func suggest(
        summary: CumulativeSummary,
        openSuggestions: [MeetingEvent],
        recordedEvents: [MeetingEvent],
        recentTranscript: String,
        maxSuggestions: Int,
        style: SummaryStyle = .builtin
    ) -> [LLMMessage] {
        let extra = style.extraEventInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraEventInstructions)"

        let system = """
        You are an attentive note-taker watching a live meeting. Based on the
        running summary and the recent transcript slice, propose at most
        \(maxSuggestions) NEW agenda items that the group has NOT touched yet
        but probably should — gaps, unanswered angles, missing stakeholders,
        risks the discussion is implicitly assuming away. Output JSON only.

        REQUIRED top-level shape:
        {"suggestions":[{"text":string,"rationale":string?,"resolved":boolean,"resolution":string?}]}

        Rules:
        - Propose ONLY items that are not already in the summary, not in the
          OPEN suggestions list, and not in the RECORDED items list below.
          If everything important is covered, return {"suggestions":[]}.
        - `text` is one specific topic the group should discuss next. Self-
          contained, ≤ 60 chars (JP) / ≤ 30 words. No vague "talk about X".
        - Use the same language as the summary.
        - Do NOT invent facts. Speculate about angles the group is missing,
          not about what they decided.
        - Do not duplicate within this response.

        Resolution detection:
        The OPEN suggestions list shows agenda items YOU previously proposed
        that are still un-discussed. If the recent transcript shows the
        group has now substantively discussed one of them, re-emit that
        item with:
          - text: copied VERBATIM from the open item
          - resolved: true
          - resolution: ≤ 20-word note on what the discussion concluded
        Otherwise leave open items out of the response.\(extra)
        """

        let summaryBlock = renderSummary(summary)
        let openBlock = renderOpenSuggestions(openSuggestions)
        let recordedBlock = renderRecordedEvents(recordedEvents)
        let transcriptBlock = recentTranscript.isEmpty
            ? "_(none yet)_"
            : recentTranscript

        let user = """
        ## Running summary
        \(summaryBlock)

        ## OPEN suggestions you previously proposed
        \(openBlock)

        ## Items already captured by the extractor (don't repropose)
        \(recordedBlock)

        ## Recent transcript slice (last few exchanges only)
        \(transcriptBlock)
        """

        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }

    static func renderSummary(_ summary: CumulativeSummary) -> String {
        guard !summary.sections.isEmpty else { return "_(empty)_" }
        var lines: [String] = []
        for section in summary.sections {
            lines.append("### \(section.title)")
            for bullet in section.bullets {
                lines.append("- \(bullet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func renderOpenSuggestions(_ events: [MeetingEvent]) -> String {
        let open = events.filter { $0.kind == .agendaSuggestion && !$0.resolved }
        guard !open.isEmpty else { return "_(none)_" }
        return open.map { "- \($0.text)" }.joined(separator: "\n")
    }

    static func renderRecordedEvents(_ events: [MeetingEvent]) -> String {
        let relevant = events.filter { $0.kind != .agendaSuggestion }
        guard !relevant.isEmpty else { return "_(none)_" }
        return relevant.map { e in
            "- [\(e.kind.rawValue)] \(e.text)"
        }.joined(separator: "\n")
    }
}
