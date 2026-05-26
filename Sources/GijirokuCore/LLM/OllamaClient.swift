import Foundation

public struct OllamaClient: LLMClient {
    public let baseURL: URL
    public let temperature: Double
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        temperature: Double = 0.2,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.temperature = temperature
        self.session = session
    }

    public func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct RequestBody: Encodable {
            let model: String
            let messages: [LLMMessage]
            let stream: Bool
            let format: String?
            let options: Options
            struct Options: Encodable {
                let temperature: Double
            }
        }
        let body = RequestBody(
            model: model,
            messages: messages,
            stream: false,
            format: format == .json ? "json" : nil,
            options: .init(temperature: temperature)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.httpFailure(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct ChatResponse: Decodable {
            let message: Message
            struct Message: Decodable {
                let role: String
                let content: String
            }
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content
    }
}

public enum OllamaError: Error, Equatable {
    case httpFailure(status: Int)
}
