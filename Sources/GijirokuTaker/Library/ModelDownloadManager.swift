import Foundation
import OSLog
import SwiftUI
import UserNotifications
import GijirokuCore
import GijirokuLLM

/// Coordinates pre-flight downloads of MLX models so the user does not pay the
/// multi-GB HuggingFace download on their first Start. Owns the download
/// lifecycle, publishes per-model progress for SwiftUI, and posts a macOS local
/// notification when a download completes.
///
/// The manager keeps the underlying MLXClient alive only for the duration of the
/// download. Once the model is on disk, ARC drops the client and frees the
/// in-memory weights — the HuggingFace cache persists, so the real recording
/// path (AppModel → MLXClient.ensureLoaded) re-loads from disk in seconds
/// instead of minutes.
@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()

    enum State: Equatable {
        case idle
        case downloading(fraction: Double)
        case completed
        case failed(message: String)
    }

    @Published private(set) var stateByModel: [String: State] = [:]

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "ModelDownloadManager")
    private var activeClient: MLXClient?
    private var activeTask: Task<Void, Never>?
    private var activePollTask: Task<Void, Never>?
    private var activeModelID: String?

    private init() {}

    func state(for modelID: String) -> State {
        if let s = stateByModel[modelID] { return s }
        return MLXAvailableModelsProvider.isDownloaded(modelID) ? .completed : .idle
    }

    /// Starts a background download for the given MLX model id. No-op when:
    /// - the same model id is already in flight,
    /// - the model is already cached on disk.
    /// A different model id supersedes the current one — the prior task is
    /// cancelled (the underlying HuggingFace files-in-flight may still finish
    /// in the background, which is fine — they'll satisfy a future request).
    func prefetchMLX(_ modelID: String) {
        if MLXAvailableModelsProvider.isDownloaded(modelID) {
            stateByModel[modelID] = .completed
            fputs("[ModelDownloadManager] \(modelID) already cached — skip prefetch\n", stderr)
            return
        }
        if activeModelID == modelID, case .downloading = stateByModel[modelID] {
            return
        }
        activeTask?.cancel()
        activePollTask?.cancel()
        activeClient = nil
        activeModelID = modelID
        stateByModel[modelID] = .downloading(fraction: 0)
        fputs("[ModelDownloadManager] prefetch start \(modelID)\n", stderr)

        // Resolve expected total bytes for the disk-size fallback poller. If
        // the catalog entry doesn't carry a size hint we still poll (clamped
        // at 0.99) so the user sees the bar moving in some direction.
        let expectedBytes = MLXModelCatalog.recommended
            .first(where: { $0.id == modelID })?
            .sizeEstimateBytes ?? 0

        let client = MLXClient { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                guard self.activeModelID == progress.modelID else { return }
                let f = min(progress.fraction, 0.999)
                self.stateByModel[progress.modelID] = .downloading(fraction: f)
            }
        }
        activeClient = client

        // Fallback progress: poll the model's HuggingFace cache directory
        // every second. The MLX progress callback was reported as not firing
        // for some setups — by watching disk growth directly we always show
        // some forward motion as long as bytes are landing.
        activePollTask = Task { @MainActor [weak self] in
            let cacheDir = MLXAvailableModelsProvider.modelCacheDirectory(for: modelID)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                guard let self else { break }
                guard self.activeModelID == modelID else { break }
                let bytes = MLXAvailableModelsProvider.directorySizeBytes(cacheDir)
                // Only push the disk-derived fraction when:
                // - we have an expected total
                // - the current state is `.downloading` (not yet completed)
                // - the disk-derived value is bigger than what we already show
                //   (the MLX callback wins when it's ahead; we never regress).
                guard case .downloading(let current) = self.stateByModel[modelID] else { break }
                if expectedBytes > 0 {
                    let f = min(0.99, Double(bytes) / Double(expectedBytes))
                    if f > current {
                        self.stateByModel[modelID] = .downloading(fraction: f)
                    }
                }
            }
        }

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await client.preload(modelID: modelID)
                if Task.isCancelled { return }
                self.activePollTask?.cancel()
                self.stateByModel[modelID] = .completed
                fputs("[ModelDownloadManager] prefetch done \(modelID)\n", stderr)
                await self.notifyCompletion(modelID: modelID)
            } catch is CancellationError {
                fputs("[ModelDownloadManager] prefetch cancelled \(modelID)\n", stderr)
                self.activePollTask?.cancel()
            } catch {
                if Task.isCancelled { return }
                fputs("[ModelDownloadManager] prefetch FAILED \(modelID): \(error.localizedDescription)\n", stderr)
                self.activePollTask?.cancel()
                self.stateByModel[modelID] = .failed(message: error.localizedDescription)
            }
            if self.activeModelID == modelID {
                self.activeClient = nil
            }
        }
    }

    /// Pull a model into Ollama via `/api/pull` and stream progress events
    /// into the same `stateByModel` machinery that drives the MLX flow. The
    /// caller is responsible for ensuring Ollama is actually running — use
    /// `OllamaClient.ping()` first for a nicer error.
    func pullOllama(_ modelID: String, baseURL: URL) {
        if activeModelID == modelID, case .downloading = stateByModel[modelID] {
            return
        }
        activeTask?.cancel()
        activePollTask?.cancel()
        activeClient = nil
        activeModelID = modelID
        stateByModel[modelID] = .downloading(fraction: 0)
        fputs("[ModelDownloadManager] ollama pull start \(modelID) baseURL=\(baseURL)\n", stderr)

        let client = OllamaClient(baseURL: baseURL)
        activeTask = Task { @MainActor [weak self] in
            do {
                for try await event in client.pull(model: modelID) {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    guard self.activeModelID == modelID else { return }
                    if let frac = event.fraction {
                        self.stateByModel[modelID] = .downloading(fraction: min(0.999, frac))
                    }
                    if event.isFinished {
                        self.stateByModel[modelID] = .completed
                        fputs("[ModelDownloadManager] ollama pull done \(modelID)\n", stderr)
                        await self.notifyCompletion(modelID: modelID)
                        return
                    }
                }
                // Stream finished without a `success` event — treat as done
                // anyway (Ollama occasionally closes the connection slightly
                // before emitting it).
                if let self, self.activeModelID == modelID,
                   case .downloading = self.stateByModel[modelID] {
                    self.stateByModel[modelID] = .completed
                    fputs("[ModelDownloadManager] ollama pull stream ended \(modelID)\n", stderr)
                    await self.notifyCompletion(modelID: modelID)
                }
            } catch is CancellationError {
                fputs("[ModelDownloadManager] ollama pull cancelled \(modelID)\n", stderr)
            } catch {
                if Task.isCancelled { return }
                fputs("[ModelDownloadManager] ollama pull FAILED \(modelID): \(error.localizedDescription)\n", stderr)
                self?.stateByModel[modelID] = .failed(message: error.localizedDescription)
            }
        }
    }

    private func notifyCompletion(modelID: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.string("model.download.notification_title")
        content.body = L10n.format("model.download.notification_body_format", modelID)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "model-download-\(modelID)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
