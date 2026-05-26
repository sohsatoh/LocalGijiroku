import Foundation
import OSLog
import GijirokuCore
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

public actor MLXClient: LLMClient {
    public struct Progress: Sendable {
        public let modelID: String
        public let fraction: Double
    }

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "MLXClient")
    private var modelContainer: ModelContainer?
    private var loadedModelID: String?
    private var loadingTask: Task<ModelContainer, Error>?
    private let progressHandler: (@Sendable (Progress) -> Void)?

    public init(progressHandler: (@Sendable (Progress) -> Void)? = nil) {
        self.progressHandler = progressHandler
        fputs("[MLXClient] init\n", stderr)
    }

    public func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat
    ) async throws -> String {
        fputs("[MLXClient] chat() called model=\(model)\n", stderr)
        let container = try await ensureLoaded(modelID: model)
        logger.notice("chat() container ready, building session")

        let systemPrompt = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let userPrompt = messages
            .filter { $0.role != .system }
            .map { msg -> String in
                switch msg.role {
                case .user: return msg.content
                case .assistant: return "(previous assistant) \(msg.content)"
                default: return msg.content
                }
            }
            .joined(separator: "\n\n")

        let formatHint: String? = format == .json
            ? "Respond with ONLY a JSON object. No prose, no markdown fences."
            : nil

        let session = ChatSession(
            container,
            instructions: [systemPrompt, formatHint].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n"),
            generateParameters: GenerateParameters(maxTokens: 800, temperature: 0.2)
        )
        logger.notice("chat() respond() starting userPrompt=\(userPrompt.prefix(80), privacy: .public)")
        let response = try await session.respond(to: userPrompt)
        logger.notice("chat() got response length=\(response.count, privacy: .public)")
        return response
    }

    /// Ensures the model for the given ID is loaded. Concurrent callers for the
    /// same model wait on a shared loading task; a different model id triggers
    /// an unload-then-reload.
    private func ensureLoaded(modelID: String) async throws -> ModelContainer {
        if let modelContainer, loadedModelID == modelID {
            return modelContainer
        }
        if let existing = loadingTask, loadedModelID == modelID {
            return try await existing.value
        }
        if loadedModelID != modelID {
            modelContainer = nil
            loadingTask = nil
        }
        logger.notice("ensureLoaded: starting download/load for \(modelID, privacy: .public)")
        let id = modelID
        let progress = progressHandler
        let log = logger
        let task = Task<ModelContainer, Error> {
            do {
                let configuration = ModelConfiguration(id: id)
                let container = try await loadModelContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration
                ) { p in
                    progress?(Progress(modelID: id, fraction: p.fractionCompleted))
                    if Int(p.fractionCompleted * 100) % 10 == 0 {
                        log.notice("download progress \(id, privacy: .public): \(Int(p.fractionCompleted * 100), privacy: .public)%")
                    }
                }
                log.notice("ensureLoaded: container ready for \(id, privacy: .public)")
                return container
            } catch {
                log.error("ensureLoaded: load failed \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        loadingTask = task
        loadedModelID = modelID
        let container = try await task.value
        modelContainer = container
        return container
    }
}
