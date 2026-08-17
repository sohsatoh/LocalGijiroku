import Foundation
import OSLog
import GijirokuCore
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Minimal Sendable counter used by the download progress closure to
/// throttle stderr log spam to one line per 10% bucket. Replaces a captured
/// `var Int` that the Swift 6 concurrency checker rightly flags.
private final class ProgressTenth: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = -1

    func swap(_ new: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}

/// ChatSession is a reference type with its own `SerialAccessContainer<Cache>`
/// for internal cache mutation but isn't declared `Sendable` upstream. We
/// always go through MLXClient's actor mailbox, which serializes access on
/// our side, so the retroactive @unchecked Sendable is safe for our usage.
extension ChatSession: @retroactive @unchecked Sendable {}

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

    /// In-memory ChatSession cache, keyed by (model + system prompt + format).
    /// Reusing a session keeps its internal KV cache hot — the multi-thousand-
    /// token system prompt only needs to be prefilled on the FIRST call for
    /// each key; subsequent calls within the same MLXClient lifetime skip
    /// that prefill (typically ~1–3 s per call on M-series silicon).
    ///
    /// Tradeoff: ChatSession appends each turn to its history, so the model
    /// technically sees previous user/assistant exchanges as context. Our
    /// system prompts are strict ("output JSON matching schema, ignore
    /// extraneous context"), so this should not affect output quality —
    /// but we still rotate the session every `maxTurnsPerSession` turns
    /// to bound memory growth and reset accumulated context.
    ///
    /// Bounded by `maxConcurrentSessions` with LRU eviction. The summary
    /// loop uses ~6 distinct system prompts (appendDelta / consolidate /
    /// regenerate / EventExtractor / AgendaSuggester / TopicHeadingDetector /
    /// generateTitle), and a KV cache for a 4B model at 12 turns × 1k
    /// tokens can sit at ~4 GB each — without an upper bound the resident
    /// set hits double-digit GB territory in long recordings.
    private var sessions: [String: ChatSession] = [:]
    private var sessionAccessOrder: [String] = []
    private var turnsPerSession: [String: Int] = [:]
    private let maxTurnsPerSession = 6
    private let maxConcurrentSessions = 3

    public init(progressHandler: (@Sendable (Progress) -> Void)? = nil) {
        self.progressHandler = progressHandler
        fputs("[MLXClient] init\n", stderr)
    }

    /// Downloads + loads the model into memory without running inference.
    /// Used by the onboarding prefetch flow so the user does not pay the
    /// download cost on first Start. Discarding the client after preload
    /// releases the in-memory weights but keeps the on-disk HuggingFace
    /// cache, so subsequent ensureLoaded calls only re-map from disk.
    public func preload(modelID: String) async throws {
        _ = try await ensureLoaded(modelID: modelID)
    }

    public func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat,
        maxTokens: Int
    ) async throws -> String {
        fputs("[MLXClient] chat() called model=\(model) maxTokens=\(maxTokens)\n", stderr)
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

        // MLX swift has no grammar-constrained decoding hook, so .jsonSchema
        // degrades to the same prompt-only nudge as .json. The schema bytes
        // are ignored here — the SummaryEngine / EventExtractor parsers stay
        // tolerant for this backend.
        let wantsJSON: Bool
        switch format {
        case .text: wantsJSON = false
        case .json, .jsonSchema: wantsJSON = true
        }
        let formatHint: String? = wantsJSON
            ? "Respond with ONLY a JSON object. No prose, no markdown fences."
            : nil

        let instructions = [systemPrompt, formatHint]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n\n")
        let sessionKey = Self.sessionKey(model: model, instructions: instructions)

        // Reuse an existing ChatSession for the same (model, system prompt)
        // pair — its KV cache already encodes the system prompt prefill.
        // Rotate when the turn count gets high so the cache doesn't grow
        // unbounded (and so the model isn't dragging too much stale context).
        let turns = turnsPerSession[sessionKey] ?? 0
        if turns >= maxTurnsPerSession {
            evictSession(forKey: sessionKey)
            fputs("[MLXClient] rotating session (turn cap reached) key=\(sessionKey.suffix(8))\n", stderr)
        }
        // LRU cap: if a fresh session would push us past the concurrent
        // limit, evict the least-recently-used. The summary loop keeps
        // ~6 distinct keys hot; capping at 3 means the two least useful
        // keys (typically generateTitle / classifier, which run rarely)
        // get re-prefilled on demand instead of permanently occupying
        // GBs of KV cache.
        if sessions[sessionKey] == nil, sessions.count >= maxConcurrentSessions {
            if let oldest = sessionAccessOrder.first {
                evictSession(forKey: oldest)
                fputs("[MLXClient] evicting LRU session key=\(oldest.suffix(8)) (cap=\(maxConcurrentSessions))\n", stderr)
            }
        }
        // Token budget is per-call; temperature 0 = deterministic greedy
        // decoding for stable JSON output.
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)
        let session: ChatSession
        let origin: SessionOrigin
        if let cached = sessions[sessionKey] {
            cached.generateParameters = params
            session = cached
            origin = .memory
        } else if let restored = Self.loadDiskCache(for: sessionKey, model: container, params: params) {
            // Disk cache hit — restored session already has the system prompt
            // (and one prior dummy turn) encoded in its KV cache. Do NOT pass
            // instructions again; the cache already represents them.
            sessions[sessionKey] = restored
            session = restored
            // Disk-restored sessions count as turn 1 (the persisted exchange).
            turnsPerSession[sessionKey] = 1
            origin = .disk
        } else {
            session = ChatSession(
                container,
                instructions: instructions.isEmpty ? nil : instructions,
                generateParameters: params
            )
            sessions[sessionKey] = session
            origin = .fresh
        }
        touchLRU(sessionKey)
        let recordedTurns = turnsPerSession[sessionKey] ?? 0
        fputs("[MLXClient] chat() session \(origin.label) turns=\(recordedTurns)/\(maxTurnsPerSession)\n", stderr)

        logger.notice("chat() respond() starting userPrompt=\(userPrompt.prefix(80), privacy: .public)")
        let response = try await session.respond(to: userPrompt)
        turnsPerSession[sessionKey] = recordedTurns + 1
        logger.notice("chat() got response length=\(response.count, privacy: .public)")

        // After the first chat for this key, persist the cache so a future
        // MLXClient instance (e.g. next recording, next app launch) can
        // warm-start without re-prefilling the system prompt.
        if origin == .fresh {
            await Self.persistCache(session: session, key: sessionKey)
        }
        return response
    }

    /// Where each session's first-turn cache came from. Surfaced in the log
    /// so the user can confirm the prefix cache is actually firing.
    private enum SessionOrigin {
        case fresh
        case memory
        case disk

        var label: String {
            switch self {
            case .fresh: return "FRESH"
            case .memory: return "REUSED-MEM"
            case .disk: return "REUSED-DISK"
            }
        }
    }

    /// Application Support folder under which we keep persistent prompt
    /// caches keyed by sessionKey hash. Returns nil if Application Support
    /// can't be located (sandboxed weirdness, unusual env).
    private static var diskCacheDir: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("GijirokuTaker/PromptCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func diskCacheURL(for sessionKey: String) -> URL? {
        guard let dir = diskCacheDir else { return nil }
        // Strip `/` so the model id portion doesn't create unexpected
        // subdirectories. The hash portion is already filesystem-safe.
        let safe = sessionKey.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).safetensors")
    }

    /// Attempts to load a persisted KV cache for `key`. Returns a ChatSession
    /// initialized with that cache and ready to `respond()`. Returns nil if
    /// no cache exists or loading fails — caller should fall back to a fresh
    /// session.
    private static func loadDiskCache(
        for key: String,
        model: ModelContainer,
        params: GenerateParameters
    ) -> ChatSession? {
        guard let url = diskCacheURL(for: key),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let (cache, _) = try loadPromptCache(url: url)
            guard !cache.isEmpty else { return nil }
            fputs("[MLXClient] loaded prompt cache from disk key=\(key.suffix(8))\n", stderr)
            // No `instructions` here — they're baked into the loaded cache.
            return ChatSession(
                model,
                cache: cache,
                generateParameters: params
            )
        } catch {
            fputs("[MLXClient] loadPromptCache FAILED key=\(key.suffix(8)) error=\(error.localizedDescription) — falling back to fresh\n", stderr)
            // Stale or incompatible cache (e.g. different model). Best effort
            // cleanup so we don't keep hitting it.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Save the session's current KV cache to disk so a future MLXClient
    /// instance can warm-start without re-prefilling the system prompt.
    /// Best effort — failures are logged but never bubbled to the caller.
    private static func persistCache(session: ChatSession, key: String) async {
        guard let url = diskCacheURL(for: key) else { return }
        do {
            try await session.saveCache(to: url)
            fputs("[MLXClient] persisted prompt cache key=\(key.suffix(8))\n", stderr)
        } catch {
            fputs("[MLXClient] saveCache FAILED key=\(key.suffix(8)) error=\(error.localizedDescription)\n", stderr)
        }
    }

    /// Drop the in-memory session bucket for `key`, releasing its KV cache.
    /// Disk-persisted cache is preserved — the next call for the same key
    /// can warm-start from disk without re-prefilling the system prompt.
    /// Single source of truth for "forget this session" so LRU eviction
    /// and turn-cap rotation stay in sync on the three side data
    /// structures (`sessions`, `turnsPerSession`, `sessionAccessOrder`).
    private func evictSession(forKey key: String) {
        sessions[key] = nil
        turnsPerSession[key] = nil
        sessionAccessOrder.removeAll { $0 == key }
    }

    /// Move `key` to the end of the LRU order. Called after any successful
    /// session lookup / creation so the cap eviction picks genuinely
    /// stale keys, not whatever happened to be inserted first.
    private func touchLRU(_ key: String) {
        sessionAccessOrder.removeAll { $0 == key }
        sessionAccessOrder.append(key)
    }

    /// Drop every cached session. Called by AppModel/LibraryModel at
    /// recording-end and regeneration-end as a hard ceiling on resident
    /// KV cache. The KV caches the summary loop accumulates over a long
    /// recording can sit at tens of GB; clearing them on session
    /// boundaries keeps the process's resident set from drifting up
    /// across recordings.
    public func flushSessionCache() {
        let count = sessions.count
        sessions.removeAll()
        turnsPerSession.removeAll()
        sessionAccessOrder.removeAll()
        fputs("[MLXClient] flushSessionCache cleared \(count) session(s)\n", stderr)
    }

    /// Stable key for the session cache. Hashing the instructions (rather
    /// than embedding the full text) keeps the map small even when the
    /// system prompt is multi-KB long. SHA-256 truncated to 16 hex chars is
    /// more than enough — collisions across the 3-4 prompts this app uses
    /// are astronomically unlikely.
    private static func sessionKey(model: String, instructions: String) -> String {
        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(instructions)
        return "\(model)|\(String(hasher.finalize(), radix: 16))"
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
            // Sessions hold a strong ref to the old ModelContainer; drop
            // them so we don't keep an obsolete model resident. Also
            // clear the LRU index so the next model's first session
            // doesn't get evicted by stale entries.
            sessions.removeAll()
            turnsPerSession.removeAll()
            sessionAccessOrder.removeAll()
        }
        // fputs to stderr so the Log Viewer (and any external `nohup` sink)
        // sees these events. OSLog .notice is suppressed inside SPM-bundled
        // apps, which made earlier "progress not visible" debugging blind.
        fputs("[MLXClient] ensureLoaded start id=\(modelID)\n", stderr)
        let id = modelID
        let progress = progressHandler
        let log = logger
        let task = Task<ModelContainer, Error> {
            do {
                let configuration = ModelConfiguration(id: id)
                // Atomic int (boxed) so a closure crossing the Sendable
                // boundary can mutate it without triggering Swift 6's data
                // race diagnostic. Using NSLock would be more correct but
                // overkill for a debug counter; the closure is called from
                // one downloader thread at a time anyway.
                let lastTenth = ProgressTenth()
                let container = try await loadModelContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration
                ) { p in
                    progress?(Progress(modelID: id, fraction: p.fractionCompleted))
                    // Log once per 10% bucket to stderr so we can verify the
                    // HuggingFace downloader is actually invoking the callback.
                    let tenth = Int(p.fractionCompleted * 10)
                    if lastTenth.swap(tenth) != tenth {
                        fputs("[MLXClient] download progress \(id): \(Int(p.fractionCompleted * 100))%\n", stderr)
                    }
                }
                fputs("[MLXClient] ensureLoaded ready id=\(id)\n", stderr)
                return container
            } catch {
                fputs("[MLXClient] ensureLoaded FAILED id=\(id): \(error.localizedDescription)\n", stderr)
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
