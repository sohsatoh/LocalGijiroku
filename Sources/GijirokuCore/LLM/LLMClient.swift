import Foundation

public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LLMResponseFormat: Sendable {
    case text
    /// Loose "respond with JSON" mode — relies on the prompt and the model's
    /// JSON heuristics. MLX swift uses this since the wrapper has no
    /// constrained-decoding hook; Ollama uses its legacy `"json"` mode.
    case json
    /// Strict JSON Schema mode (Ollama 0.5+, llama.cpp grammar). Pass the
    /// schema as serialized JSON; the LLM is constrained to produce an
    /// output that matches. This is what eliminates the "LLM forgot the
    /// envelope" class of parse failures we hit on small models.
    /// Backends that don't support grammar-constrained decoding (currently
    /// MLX in this app) treat this as if it were `.json`.
    case jsonSchema(Data)

    /// Convenience accessor used by clients that need to peek at the schema
    /// without unwrapping the case manually.
    public var schemaData: Data? {
        if case .jsonSchema(let d) = self { return d }
        return nil
    }
}

public protocol LLMClient: Sendable {
    /// Generate a single response.
    /// - Parameters:
    ///   - maxTokens: hard upper bound on output tokens. Pick this per task —
    ///     a 20-char title needs ~60, the summary engine might want ~1500.
    ///     Smaller budgets mean shorter worst-case latency.
    func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat,
        maxTokens: Int
    ) async throws -> String
}

public extension LLMClient {
    /// Back-compat overload for call sites that don't yet care about the
    /// token budget. Defaults to 2000 — generous enough for the longest
    /// summary turn we currently produce.
    func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat
    ) async throws -> String {
        try await chat(model: model, messages: messages, format: format, maxTokens: 2000)
    }
}
