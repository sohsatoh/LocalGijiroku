import Foundation
import GijirokuCore

public enum LLMBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case mlx
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mlx: return "MLX (オンデバイス・依存なし)"
        case .ollama: return "Ollama (外部サーバー)"
        }
    }
}

public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let backend: LLMBackend
    public let sizeEstimate: String?
    public let isDownloaded: Bool

    public init(id: String, displayName: String, backend: LLMBackend, sizeEstimate: String? = nil, isDownloaded: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.sizeEstimate = sizeEstimate
        self.isDownloaded = isDownloaded
    }
}

public protocol AvailableModelsProvider: Sendable {
    var backend: LLMBackend { get }
    func availableModels() async -> [ModelInfo]
}

public enum MLXModelCatalog {
    /// HuggingFace `mlx-community/` 系のキュレートモデルリスト。
    /// 日本語/英語の両対応・4bit 量子化済みでローカル動作向け。
    public static let recommended: [ModelInfo] = [
        .init(id: "mlx-community/Qwen3-4B-4bit", displayName: "Qwen3 4B (4bit, 多言語)", backend: .mlx, sizeEstimate: "~2.5 GB"),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen2.5 7B Instruct (4bit, 多言語)", backend: .mlx, sizeEstimate: "~4.2 GB"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B Instruct (4bit)", backend: .mlx, sizeEstimate: "~1.8 GB"),
        .init(id: "mlx-community/gemma-3-4b-it-4bit", displayName: "Gemma 3 4B IT (4bit)", backend: .mlx, sizeEstimate: "~2.5 GB"),
        .init(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", displayName: "Mistral 7B Instruct v0.3 (4bit)", backend: .mlx, sizeEstimate: "~4.0 GB"),
    ]
}

public struct MLXAvailableModelsProvider: AvailableModelsProvider {
    public let backend: LLMBackend = .mlx

    public init() {}

    public func availableModels() async -> [ModelInfo] {
        let downloadedIDs = Self.scanDownloadedModelIDs()
        return MLXModelCatalog.recommended.map { model in
            ModelInfo(
                id: model.id,
                displayName: model.displayName,
                backend: model.backend,
                sizeEstimate: model.sizeEstimate,
                isDownloaded: downloadedIDs.contains(model.id)
            )
        }
    }

    /// Scans `~/.cache/huggingface/hub/` for entries named like
    /// `models--<owner>--<name>` and returns the corresponding `owner/name`
    /// HuggingFace IDs.
    private static func scanDownloadedModelIDs() -> Set<String> {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var ids = Set<String>()
        for entry in entries {
            guard entry.hasPrefix("models--") else { continue }
            let rest = String(entry.dropFirst("models--".count))
            let parts = rest.components(separatedBy: "--")
            guard parts.count == 2 else { continue }
            ids.insert("\(parts[0])/\(parts[1])")
        }
        return ids
    }
}

public struct OllamaAvailableModelsProvider: AvailableModelsProvider {
    public let backend: LLMBackend = .ollama
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func availableModels() async -> [ModelInfo] {
        struct TagsResponse: Decodable {
            let models: [Model]
            struct Model: Decodable {
                let name: String
                let size: Int64?
            }
        }
        let url = baseURL.appendingPathComponent("api/tags")
        guard let (data, _) = try? await session.data(from: url),
              let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            return []
        }
        return decoded.models.map { m in
            ModelInfo(
                id: m.name,
                displayName: m.name,
                backend: .ollama,
                sizeEstimate: m.size.map { Self.humanReadable($0) },
                isDownloaded: true
            )
        }
    }

    private static func humanReadable(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
