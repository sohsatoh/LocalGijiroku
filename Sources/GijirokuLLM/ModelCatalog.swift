import Foundation
import GijirokuCore

public enum LLMBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case mlx
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        // GijirokuLLM is shared with the CLI; we don't pull L10n here.
        // The SwiftUI Settings view in the app target localizes the
        // label when rendering by mapping rawValue → key.
        switch self {
        case .mlx: return "MLX (on-device)"
        case .ollama: return "Ollama (external server)"
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
    /// Curated list of `mlx-community/` HuggingFace models, sorted from
    /// lightest to largest. Display names are kept in English so the same
    /// label renders cleanly in both Japanese and English UI; the size /
    /// suitability hints (small / recommended / etc.) are added separately
    /// by the picker views via the localized tag table.
    ///
    /// Note: Qwen3 family is a reasoning model that emits `<think>` blocks
    /// (the app already strips them).
    public static let recommended: [ModelInfo] = [
        // Light (small / fast / lower quality)
        .init(id: "mlx-community/Qwen3-1.7B-4bit", displayName: "Qwen3 1.7B 4bit", backend: .mlx, sizeEstimate: "~1.1 GB"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B Instruct 4bit", backend: .mlx, sizeEstimate: "~1.8 GB"),
        // Standard (balanced — Qwen3 4B is the default)
        .init(id: "mlx-community/Qwen3-4B-4bit", displayName: "Qwen3 4B 4bit", backend: .mlx, sizeEstimate: "~2.5 GB"),
        .init(id: "mlx-community/gemma-3-4b-it-4bit", displayName: "Gemma 3 4B IT 4bit", backend: .mlx, sizeEstimate: "~2.5 GB"),
        // Mid (higher quality if you have RAM headroom)
        .init(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", displayName: "Mistral 7B Instruct v0.3 4bit", backend: .mlx, sizeEstimate: "~4.0 GB"),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen2.5 7B Instruct 4bit", backend: .mlx, sizeEstimate: "~4.2 GB"),
        .init(id: "mlx-community/gemma-2-9b-it-4bit", displayName: "Gemma 2 9B IT 4bit", backend: .mlx, sizeEstimate: "~5.4 GB"),
        // Large (Apple Silicon + 32GB+ RAM)
        .init(id: "mlx-community/Llama-3.1-8B-Instruct-4bit", displayName: "Llama 3.1 8B Instruct 4bit", backend: .mlx, sizeEstimate: "~4.5 GB"),
        .init(id: "mlx-community/Qwen2.5-14B-Instruct-4bit", displayName: "Qwen2.5 14B Instruct 4bit", backend: .mlx, sizeEstimate: "~8.2 GB"),
    ]
}

/// Localized tags shown next to model picker entries. Kept here (not in the
/// catalog struct itself) so the App layer can drive localization. Used by
/// SettingsView / OnboardingView through a helper.
public enum ModelTag: String, Sendable {
    case lightweight
    case `default`
    case multilingual
    case highAccuracy
    case largeMemory
}

public extension ModelInfo {
    /// Returns the catalog tag for built-in MLX models, or nil for downloaded
    /// Ollama models (we don't tag those).
    var catalogTag: ModelTag? {
        switch id {
        case "mlx-community/Qwen3-1.7B-4bit": return .lightweight
        case "mlx-community/Qwen3-4B-4bit": return .default
        case "mlx-community/Qwen2.5-7B-Instruct-4bit": return .multilingual
        case "mlx-community/gemma-2-9b-it-4bit": return .highAccuracy
        case "mlx-community/Qwen2.5-14B-Instruct-4bit": return .largeMemory
        default: return nil
        }
    }
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
