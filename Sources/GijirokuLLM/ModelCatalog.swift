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
    /// Curated list of `mlx-community/` HuggingFace models for meeting note
    /// generation, sorted lightest → largest.
    ///
    /// Selection criteria:
    /// - Instruction-tuned (this app asks for JSON output, not chat).
    /// - Strong multilingual or Japanese capability (most meetings are JP).
    /// - Avoid pure reasoning models (Qwen3, DeepSeek R1) as defaults —
    ///   they spend output tokens on `<think>` chain-of-thought and often
    ///   truncate before the JSON closes. They're still kept in the list
    ///   as opt-in alternatives.
    ///
    /// Display names are English so the same label renders cleanly in both
    /// JP and EN UI; size / suitability hints come from `catalogTag`.
    public static let recommended: [ModelInfo] = [
        // Light (~1–2 GB, fast on any Apple Silicon)
        .init(id: "mlx-community/gemma-2-2b-it-4bit", displayName: "Gemma 2 2B IT 4bit", backend: .mlx, sizeEstimate: "~1.5 GB"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B Instruct 4bit", backend: .mlx, sizeEstimate: "~1.8 GB"),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen2.5 3B Instruct 4bit", backend: .mlx, sizeEstimate: "~1.9 GB"),
        // Experimental — Gemma 4 E2B IT 4bit. mlx-community ships it as
        // `Gemma4ForConditionalGeneration` (text + audio + vision), and
        // it's the most-downloaded gemma-4 variant on mlx-community.
        // mlx-swift-lm support is UNVERIFIED — Gemma 3 hit a v_proj
        // shape mismatch (see exclusion note below) and Gemma 4 may
        // share the same path. Surfaced here so a real chat() call can
        // tell us whether the loader handles it; if it doesn't, remove
        // this entry and append it to the exclusion comment below.
        .init(id: "mlx-community/gemma-4-e2b-it-4bit", displayName: "Gemma 4 E2B IT 4bit (experimental)", backend: .mlx, sizeEstimate: "~1.7 GB"),
        // Recommended default — Qwen3 Instruct-2507 is non-reasoning (no
        // `<think>` blocks), instruction-tuned, multilingual, and small
        // enough that the first-Start download is reasonable.
        .init(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", displayName: "Qwen3 4B Instruct (2507) 4bit", backend: .mlx, sizeEstimate: "~2.5 GB"),
        // Mid (~4–6 GB, better quality, well-supported by MLX swift)
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen2.5 7B Instruct 4bit", backend: .mlx, sizeEstimate: "~4.2 GB"),
        .init(id: "mlx-community/gemma-2-9b-it-4bit", displayName: "Gemma 2 9B IT 4bit", backend: .mlx, sizeEstimate: "~5.4 GB"),
        // Large (Apple Silicon + 32 GB+ unified memory)
        .init(id: "mlx-community/Qwen2.5-14B-Instruct-4bit", displayName: "Qwen2.5 14B Instruct 4bit", backend: .mlx, sizeEstimate: "~8.2 GB"),
        // Reasoning models (Qwen3 base, no Instruct) — kept for users who
        // explicitly want chain-of-thought, but not default because
        // `<think>` blocks frequently exhaust the output budget before the
        // JSON closes on this app's structured-output workloads.
        .init(id: "mlx-community/Qwen3-4B-4bit", displayName: "Qwen3 4B 4bit (reasoning)", backend: .mlx, sizeEstimate: "~2.5 GB"),
        .init(id: "mlx-community/Qwen3-1.7B-4bit", displayName: "Qwen3 1.7B 4bit (reasoning)", backend: .mlx, sizeEstimate: "~1.1 GB"),
        // NOTE: Gemma 3 family (`mlx-community/gemma-3-*`) is intentionally
        // excluded — current mlx-swift-lm misinterprets its grouped-query
        // attention layout and ensureLoaded fails with a v_proj shape
        // mismatch ("Actual [1024, 320], expected [256, 320]"). Gemma 2 9B
        // above works fine. Revisit when mlx-swift-lm ships Gemma 3 support.
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
        case "mlx-community/gemma-2-2b-it-4bit",
             "mlx-community/Llama-3.2-3B-Instruct-4bit",
             "mlx-community/Qwen2.5-3B-Instruct-4bit":
            return .lightweight
        case "mlx-community/Qwen3-4B-Instruct-2507-4bit":
            // Recommended default — non-reasoning Qwen3, ~2.5 GB, robust
            // multilingual instruction following on small Apple Silicon.
            return .default
        case "mlx-community/Qwen2.5-7B-Instruct-4bit":
            // Heavier alternative with very strong Japanese / English.
            return .multilingual
        case "mlx-community/gemma-2-9b-it-4bit":
            return .highAccuracy
        case "mlx-community/Qwen2.5-14B-Instruct-4bit":
            return .largeMemory
        default:
            return nil
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

    /// Returns owner/name IDs for all HuggingFace cache entries on disk that
    /// have a **resolvable** model (config.json + at least one weights file).
    /// A bare `models--<owner>--<name>` directory whose snapshot symlinks
    /// dangle (incomplete download) is NOT included — otherwise the UI shows
    /// "Downloaded ✓" while loadModelContainer silently re-fetches missing
    /// blobs on the next chat() call.
    public static func scanDownloadedModelIDs() -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hfCacheRoot.path) else {
            return []
        }
        var ids = Set<String>()
        for entry in entries {
            guard entry.hasPrefix("models--") else { continue }
            let rest = String(entry.dropFirst("models--".count))
            // First `--` separates owner from name. Model names can contain
            // hyphens (and theoretically `--`), so split on the first match
            // rather than `components(separatedBy:)`.
            guard let sepRange = rest.range(of: "--") else { continue }
            let owner = String(rest[..<sepRange.lowerBound])
            let name = String(rest[sepRange.upperBound...])
            let id = "\(owner)/\(name)"
            if isDownloaded(id) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Strict "is this model fully on disk and usable?" check. Walks the
    /// HuggingFace cache layout (`models--<owner>--<name>/snapshots/<sha>/`)
    /// looking for at least one snapshot whose `config.json` and weights
    /// symlinks BOTH resolve to existing blobs. Returns false for partial
    /// downloads, dangling symlinks, or "tombstone" directories left behind
    /// by an interrupted fetch.
    public static func isDownloaded(_ modelID: String) -> Bool {
        let safe = modelID.replacingOccurrences(of: "/", with: "--")
        let modelDir = hfCacheRoot.appendingPathComponent("models--\(safe)", isDirectory: true)
        let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshots = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path) else {
            return false
        }
        for snap in snapshots {
            let snapDir = snapshotsDir.appendingPathComponent(snap)
            let configPath = snapDir.appendingPathComponent("config.json").path
            // FileManager.fileExists follows symlinks; a dangling link to a
            // missing blob returns false here, which is what we want.
            guard FileManager.default.fileExists(atPath: configPath) else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: snapDir.path) else { continue }
            let hasWeights = files.contains { name in
                guard name.hasSuffix(".safetensors") || name.hasSuffix(".npz") || name.hasSuffix(".gguf") else { return false }
                return FileManager.default.fileExists(atPath: snapDir.appendingPathComponent(name).path)
            }
            if hasWeights {
                return true
            }
        }
        return false
    }

    /// Respects `HF_HOME` if set, matching the swift-huggingface convention.
    /// Falls back to the standard `~/.cache/huggingface/hub`.
    public static var hfCacheRoot: URL {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Directory where the HF hub downloader will place this model's blobs +
    /// snapshots while fetching. Used by the disk-size polling fallback to
    /// estimate download progress when the MLX progress callback misbehaves.
    public static func modelCacheDirectory(for modelID: String) -> URL {
        let safe = modelID.replacingOccurrences(of: "/", with: "--")
        return hfCacheRoot.appendingPathComponent("models--\(safe)", isDirectory: true)
    }

    /// Recursively sums allocated file sizes under `dir`. Returns 0 when the
    /// directory doesn't exist. Symlinks are followed only if the target is
    /// inside the same model dir (the standard HF cache layout).
    public static func directorySizeBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
              ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

public extension ModelInfo {
    /// Parses `sizeEstimate` strings like "~2.5 GB" / "470 MB" / "~626 MB"
    /// into a byte count for progress math. nil for unparseable / missing.
    var sizeEstimateBytes: Int64? {
        guard let raw = sizeEstimate else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let unit = parts[1].uppercased()
        let multiplier: Double
        switch unit {
        case "KB": multiplier = 1024
        case "MB": multiplier = 1024 * 1024
        case "GB": multiplier = 1024 * 1024 * 1024
        case "TB": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

public enum OllamaModelCatalog {
    /// Curated Ollama tags the user can pull with one click. Same selection
    /// criteria as the MLX catalog (instruction-tuned, multilingual, non-
    /// reasoning) but using Ollama's tag-based naming. Sizes are Ollama's
    /// reported on-disk size for the default quantization (Q4_K_M).
    public static let recommended: [ModelInfo] = [
        .init(id: "gemma2:2b", displayName: "Gemma 2 2B Instruct", backend: .ollama, sizeEstimate: "~1.6 GB"),
        .init(id: "llama3.2:3b", displayName: "Llama 3.2 3B Instruct", backend: .ollama, sizeEstimate: "~2.0 GB"),
        .init(id: "qwen2.5:3b", displayName: "Qwen2.5 3B Instruct", backend: .ollama, sizeEstimate: "~2.0 GB"),
        .init(id: "qwen2.5:7b", displayName: "Qwen2.5 7B Instruct", backend: .ollama, sizeEstimate: "~4.7 GB"),
        .init(id: "gemma2:9b", displayName: "Gemma 2 9B Instruct", backend: .ollama, sizeEstimate: "~5.4 GB"),
        .init(id: "qwen2.5:14b", displayName: "Qwen2.5 14B Instruct", backend: .ollama, sizeEstimate: "~9.0 GB"),
    ]
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
        var downloaded: [ModelInfo] = []
        if let (data, _) = try? await session.data(from: url),
           let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
            downloaded = decoded.models.map { m in
                ModelInfo(
                    id: m.name,
                    displayName: m.name,
                    backend: .ollama,
                    sizeEstimate: m.size.map { Self.humanReadable($0) },
                    isDownloaded: true
                )
            }
        }
        // Merge the curated "pull these to get started" list. Anything the
        // user has already pulled wins (richer name/size from the server);
        // remaining curated entries appear as `isDownloaded: false` so the
        // UI can show a Pull button next to them.
        let downloadedIDs = Set(downloaded.map(\.id))
        let suggestions = OllamaModelCatalog.recommended.filter {
            !downloadedIDs.contains($0.id)
        }
        return downloaded + suggestions
    }

    private static func humanReadable(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
