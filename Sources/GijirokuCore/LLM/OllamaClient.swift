import Foundation

public struct OllamaClient: LLMClient {
    public let baseURL: URL
    public let temperature: Double
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        temperature: Double = 0.0,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.temperature = temperature
        self.session = session
    }

    public func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat,
        maxTokens: Int
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Hand-build the JSON body so `format` can be either the legacy
        // string `"json"` or a JSON Schema object (Ollama 0.5+). JSONEncoder
        // can't emit a mixed-type value here without a custom encoder.
        // `num_predict` is Ollama's name for the per-request token cap.
        var bodyDict: [String: Any] = [
            "model": model,
            "stream": false,
            "options": [
                "temperature": temperature,
                "num_predict": maxTokens,
            ],
        ]
        bodyDict["messages"] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        switch format {
        case .text:
            break
        case .json:
            bodyDict["format"] = "json"
        case .jsonSchema(let schemaData):
            if let schema = try? JSONSerialization.jsonObject(with: schemaData) {
                bodyDict["format"] = schema
            } else {
                bodyDict["format"] = "json"
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

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

public enum OllamaError: LocalizedError, Equatable {
    case httpFailure(status: Int)
    case serverUnreachable
    case streamDecodingFailed

    public var errorDescription: String? {
        switch self {
        case .httpFailure(let status):
            return "Ollama HTTP \(status). Make sure the server is running and the model name is correct."
        case .serverUnreachable:
            return "Could not reach Ollama at http://127.0.0.1:11434. Is `ollama serve` running?"
        case .streamDecodingFailed:
            return "Ollama returned an unexpected response."
        }
    }
}

/// Progress event surfaced by `OllamaClient.pull`. Mirrors the JSON shape of
/// Ollama's NDJSON pull stream so callers can drive a progress bar (when
/// total + completed are present) and a status label.
public struct OllamaPullProgress: Sendable {
    public let status: String
    public let total: Int64?
    public let completed: Int64?
    public let isFinished: Bool

    public var fraction: Double? {
        guard let total, let completed, total > 0 else { return nil }
        return min(1.0, Double(completed) / Double(total))
    }
}

public extension OllamaClient {
    /// Cheap reachability probe — hits `/api/tags` and returns true on any
    /// 2xx response. Used by the UI to surface "Ollama not running, install
    /// or start it" hints instead of generic chat failures.
    func ping() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return false
        }
        return true
    }

    /// Triggers a model pull via Ollama's streaming NDJSON endpoint and
    /// yields a progress event for each chunk Ollama emits. The stream
    /// terminates when Ollama writes `{"status":"success"}` or when the
    /// HTTP connection closes — callers can `for try await` to drive UI.
    func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let url = baseURL.appendingPathComponent("api/pull")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let stream: Bool }
        req.httpBody = try? JSONEncoder().encode(Body(name: model, stream: true))
        // Capture as an immutable value so Swift 6's sending-closure check
        // doesn't flag the Task closure for racing on `var request`.
        let request = req

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        continuation.finish(throwing: OllamaError.httpFailure(
                            status: (response as? HTTPURLResponse)?.statusCode ?? -1
                        ))
                        return
                    }
                    let decoder = JSONDecoder()
                    struct Line: Decodable {
                        let status: String
                        let total: Int64?
                        let completed: Int64?
                        let error: String?
                    }
                    for try await line in bytes.lines {
                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        guard let data = line.data(using: .utf8),
                              let event = try? decoder.decode(Line.self, from: data) else {
                            // Ignore unparseable lines — Ollama occasionally
                            // emits keep-alive whitespace.
                            continue
                        }
                        if let err = event.error {
                            continuation.finish(throwing: OllamaError.httpFailure(status: -1))
                            _ = err  // surfaced via .httpFailure msg already
                            return
                        }
                        let isFinished = event.status.lowercased() == "success"
                        continuation.yield(OllamaPullProgress(
                            status: event.status,
                            total: event.total,
                            completed: event.completed,
                            isFinished: isFinished
                        ))
                        if isFinished {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
