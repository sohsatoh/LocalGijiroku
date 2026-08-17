import Testing
import Foundation
@testable import GijirokuCore

/// Captures the last request `OllamaClient` sent and returns a canned chat
/// response, without touching the network. Registered on a dedicated
/// `URLSessionConfiguration` (not `.default`) so it can't leak into other
/// tests that happen to run in the same process.
private final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBody = request.httpBodyStreamData() ?? request.httpBody
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let body = #"{"message":{"role":"assistant","content":"ok"}}"#.data(using: .utf8)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// `URLProtocol` sees `httpBody` as `nil` when the request went through
    /// `URLSession.data(for:)` — Foundation moves it to `httpBodyStream` at
    /// some point in the pipeline. Read it back out if that happened.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func makeCapturingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CapturingURLProtocol.self]
    return URLSession(configuration: config)
}

@Test func ollamaChatRequestDisablesThinking() async throws {
    CapturingURLProtocol.capturedBody = nil
    let client = OllamaClient(session: makeCapturingSession())
    _ = try await client.chat(
        model: "qwen3.5:4b",
        messages: [LLMMessage(role: .user, content: "hi")],
        format: .json,
        maxTokens: 64
    )

    let body = try #require(CapturingURLProtocol.capturedBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(json["think"] as? Bool == false)
    // Existing fields must survive the addition untouched.
    #expect(json["model"] as? String == "qwen3.5:4b")
    #expect(json["stream"] as? Bool == false)
    #expect(json["format"] as? String == "json")
    let options = try #require(json["options"] as? [String: Any])
    #expect(options["num_predict"] as? Int == 64)
}
