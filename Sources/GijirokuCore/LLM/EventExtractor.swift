import Foundation

public struct MeetingEvent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
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

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        owner: String? = nil,
        dueDate: String? = nil,
        detectedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.detectedAt = detectedAt
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

    public func extract(from segments: [TranscriptSegment]) async throws -> [MeetingEvent] {
        guard !segments.isEmpty else { return [] }
        let transcript = segments
            .map { "[\($0.source.rawValue)] \($0.text)" }
            .joined(separator: "\n")
        let messages = EventPrompt.extract(transcript: transcript, style: config.style)
        let response = try await client.chat(model: config.model, messages: messages, format: .json)
        return try Self.parse(response: response)
    }

    static func parse(response: String) throws -> [MeetingEvent] {
        struct Wrapper: Decodable {
            let events: [EventDTO]
            struct EventDTO: Decodable {
                let kind: String
                let text: String
                let owner: String?
                let due: String?
            }
        }
        let json = try SummaryEngine.extractJSONPayload(response)
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        return wrapper.events.compactMap { dto in
            guard let kind = MeetingEvent.Kind(rawValue: dto.kind.lowercased()) else { return nil }
            return MeetingEvent(
                kind: kind,
                text: dto.text,
                owner: (dto.owner?.isEmpty == false) ? dto.owner : nil,
                dueDate: (dto.due?.isEmpty == false) ? dto.due : nil
            )
        }
    }
}

enum EventPrompt {
    static func extract(transcript: String, style: SummaryStyle = .builtin) -> [LLMMessage] {
        let extra = style.extraEventInstructions.isEmpty
            ? ""
            : "\n\nAdditional user instructions:\n\(style.extraEventInstructions)"
        let system = """
        You scan meeting transcript fragments and extract structured events.
        Output JSON only, no prose, no markdown fences:
        {"events":[{"kind":"question"|"decision"|"action","text":string,"owner":string?,"due":string?}]}
        Rules:
        - kind=question: an unresolved question raised in the conversation.
        - kind=decision: a decision the participants agreed on.
        - kind=action: a concrete task. Include owner if mentioned, due if mentioned.
        - Only include events explicitly stated. Do not speculate.
        - Use the same language as the transcript.
        - If nothing qualifies, return {"events":[]}.\(extra)
        """
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: transcript),
        ]
    }
}
