import Foundation

/// Per-call output from `TopicHeadingDetector`. The actor never mutates
/// the heading list itself — it just reports what it saw — so the caller
/// stays in control of when to persist.
public struct TopicHeadingDecision: Sendable, Equatable {
    /// True only when the model is confident the topic shifted enough to
    /// warrant a new heading. `false` covers both "still the same topic"
    /// and "couldn't tell" — both should leave the existing heading in
    /// place rather than churn the UI.
    public let changed: Bool
    /// New heading text, present when `changed == true`. Always nil
    /// otherwise. Trimmed and length-capped before reaching the caller.
    public let heading: String?

    public init(changed: Bool, heading: String?) {
        self.changed = changed
        self.heading = heading
    }
}

/// Detects when the meeting's current topic has shifted and produces a
/// short Notion-style heading for the new thread. Lightweight LLM call
/// designed to run on the same cadence as the summary loop — we feed
/// only the previous heading text plus a small recent transcript slice,
/// never the full transcript, so cost stays bounded.
public actor TopicHeadingDetector {
    public struct Config: Sendable {
        public let model: String
        public let language: String
        /// Hard cap on transcript lines fed to the model. Anything before
        /// the last `recentTranscriptLineCap` lines is omitted — the
        /// running summary is the abstraction layer for older context.
        public let recentTranscriptLineCap: Int
        /// Hard cap on the heading length (graphemes) the detector will
        /// accept from the model. Anything longer is trimmed; anything
        /// missing punctuation / quotes is cleaned in `sanitize`.
        public let maxHeadingLength: Int

        public init(
            model: String = "qwen2.5:7b",
            language: String = "auto",
            recentTranscriptLineCap: Int = 30,
            maxHeadingLength: Int = 24
        ) {
            self.model = model
            self.language = language
            self.recentTranscriptLineCap = recentTranscriptLineCap
            self.maxHeadingLength = maxHeadingLength
        }
    }

    private let client: LLMClient
    private let config: Config

    public init(client: LLMClient, config: Config = .init()) {
        self.client = client
        self.config = config
    }

    static let responseFormat: LLMResponseFormat = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "changed": ["type": "boolean"],
                "heading": ["type": ["string", "null"]],
            ],
            "required": ["changed"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: schema) {
            return .jsonSchema(data)
        }
        return .json
    }()

    /// Decide whether the transcript window starting after `previousHeading`
    /// represents a new topic. The caller should pass only the segments
    /// from after the previous heading's start time; passing more is
    /// safe but wasteful.
    public func detect(
        previousHeading: TranscriptHeading?,
        recentSegments: [TranscriptSegment]
    ) async throws -> TopicHeadingDecision {
        let recent = Array(recentSegments.suffix(config.recentTranscriptLineCap))
        // Need a substantial window to judge a topic shift. Even a
        // 4-line exchange could be a side question + answer rather
        // than a true pivot. 6 lines ≈ a multi-turn exchange, which
        // is the floor for "this is the new thread, not a tangent".
        // Without an existing heading the bar is lower (we want SOME
        // initial heading once the meeting starts moving) but still
        // > 1 line.
        let minimumLines = previousHeading == nil ? 2 : 6
        guard recent.count >= minimumLines else {
            return TopicHeadingDecision(changed: false, heading: nil)
        }
        let transcript = TranscriptFormatting.toPromptLines(recent)
        let messages = HeadingPrompt.detect(
            previous: previousHeading?.text,
            transcript: transcript,
            language: config.language,
            maxLen: config.maxHeadingLength
        )
        let response = try await client.chat(
            model: config.model,
            messages: messages,
            format: Self.responseFormat,
            maxTokens: 160
        )
        do {
            return try Self.parse(response: response, maxLen: config.maxHeadingLength)
        } catch {
            fputs("[TopicHeadingDetector] parse FAILED: \(error.localizedDescription)\n", stderr)
            fputs("[TopicHeadingDetector] raw (first 400 chars): \(response.prefix(400))\n", stderr)
            throw error
        }
    }

    static func parse(response: String, maxLen: Int) throws -> TopicHeadingDecision {
        if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMParseError.emptyResponse
        }
        guard let jsonString = SummaryEngine.firstBalancedJSONValue(in: response) else {
            throw LLMParseError.noJSONObject(rawSnippet: LLMParseError.snippet(of: response))
        }
        guard let root = try? JSONSerialization.jsonObject(
            with: Data(jsonString.utf8),
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw LLMParseError.jsonDecodeFailed(
                reason: "not an object",
                rawSnippet: LLMParseError.snippet(of: jsonString)
            )
        }
        let changed = (root["changed"] as? Bool)
            ?? (root["topic_changed"] as? Bool)
            ?? false
        let rawHeading = (root["heading"] as? String)
            ?? (root["title"] as? String)
            ?? (root["topic"] as? String)
        let sanitized = rawHeading.map { sanitize($0, maxLen: maxLen) } ?? ""
        if changed && !sanitized.isEmpty {
            return TopicHeadingDecision(changed: true, heading: sanitized)
        }
        // If the model claims "changed" but produced no usable heading,
        // treat it as no-op rather than inserting a blank divider.
        return TopicHeadingDecision(changed: false, heading: nil)
    }

    /// Strip the same prefix / quote noise that small models love to
    /// emit ("Heading: …", surrounding 「」, trailing punctuation) and
    /// hard-cap to `maxLen` graphemes. Kept generous on the cap because
    /// the prompt also asks the model to stay short — the cap is a
    /// safety net, not the primary enforcement.
    static func sanitize(_ raw: String, maxLen: Int) -> String {
        var t = SummaryEngine.stripThinkBlocks(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "「", with: "")
            .replacingOccurrences(of: "」", with: "")
            .replacingOccurrences(of: "『", with: "")
            .replacingOccurrences(of: "』", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        for prefix in ["Heading:", "heading:", "Title:", "title:", "見出し:", "見出し："] {
            if t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if t.count > maxLen { t = String(t.prefix(maxLen)) }
        return t
    }
}

enum HeadingPrompt {
    static func detect(
        previous: String?,
        transcript: String,
        language: String,
        maxLen: Int
    ) -> [LLMMessage] {
        let languageLine: String
        switch language.lowercased() {
        case "ja", "japanese": languageLine = "Always answer in Japanese."
        case "en", "english": languageLine = "Always answer in English."
        default: languageLine = "Use the same language as the transcript."
        }
        let previousLine = previous.map { "Current heading: \($0)" }
            ?? "Current heading: (none yet — this is the first detection pass)"

        let system = """
        You are watching a live meeting transcript. Decide whether the
        topic of conversation has shifted enough since the current
        heading to deserve a new section heading.

        Output JSON ONLY (no markdown fences, no prose):
        {"changed": boolean, "heading": string?}

        DEFAULT, AND OVERWHELMINGLY EXPECTED, response: changed=false.
        Headings are table-of-contents anchors at the SECTION level of a
        meeting, not paragraph or sentence markers. A typical 30-minute
        meeting has 3–5 headings total — meaning roughly one heading
        every 5–10 minutes. Each call you make should treat changed=true
        as the exception, not a regular outcome.

        Return changed=true ONLY when ALL of the following hold:
        - The new thread is clearly distinct from what the current
          heading describes — a different SUBJECT entirely, not a
          deeper dive, refinement, or sub-aspect of the same subject.
        - The shift is the new main thread of the meeting, not a brief
          digression. Multiple speakers have engaged with it across
          several turns and it shows every sign of continuing.
        - The current heading is genuinely stale and would mislead
          someone scanning the transcript. "Pricing" doesn't need to
          become "Pricing discount tiers" mid-discussion — the original
          still describes the section. Only replace it when the new
          thread is so different that the old heading no longer
          remotely captures what's being discussed.

        Treat the following as NOT a topic shift (changed=false):
        - One- or two-line tangents, clarifying questions, side
          comments, recap statements, examples, definitions.
        - Sub-topics that fit naturally under the current heading.
        - Speaker handoffs without subject change.
        - The same topic re-emerging after a brief detour.

        Other rules:
        - When changed=false, set heading=null. Do not propose a heading
          you don't intend to use.
        - When changed=true, heading is a short noun-phrase title for
          the NEW thread, ≤ \(maxLen) characters, no trailing punctuation,
          no surrounding quotes. \(languageLine)
        - When the current heading is "(none yet)" and the transcript
          has substantive content (multiple exchanges on something
          concrete), return changed=true with a heading for what the
          meeting is currently about.
        - When in doubt, return changed=false. The existing heading is
          the safer default.
        """

        let user = """
        \(previousLine)

        Recent transcript slice (the only context you have — the rest of
        the meeting lives in a running summary you do NOT see):
        \(transcript)
        """

        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user),
        ]
    }
}
