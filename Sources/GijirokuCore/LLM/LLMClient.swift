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
    case json
}

public protocol LLMClient: Sendable {
    func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat
    ) async throws -> String
}
