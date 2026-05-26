import Foundation
import OSLog
import SwiftUI
import GijirokuCore
import GijirokuLLM

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "AppModel")

    @Published var isRecording: Bool = false
    @Published var transcript: [TranscriptSegment] = []
    @Published var summary: CumulativeSummary = CumulativeSummary()
    @Published var events: [MeetingEvent] = []
    @Published var statusMessage: String = L10n.string("status.idle")
    @Published var summaryProgress: SummaryProgress = .idle
    @Published var micWaveform = WaveformChannelState()
    @Published var systemWaveform = WaveformChannelState()

    private let settings: SettingsModel = .shared
    private let sessionStore: FileSessionStore

    // Recreated per session so that settings changes take effect on next Start.
    private var client: (any LLMClient)?
    private var summaryEngine: SummaryEngine?
    private var eventExtractor: EventExtractor?
    private var transcriptionEngine: WhisperTranscription?
    private var captureEngine: AudioCaptureEngine?

    private var pendingForSummary: [TranscriptSegment] = []
    private var sessionId: UUID = UUID()
    private var sessionStartedAt: Date = .now

    private var summaryLoopTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private let transcriptDeduper = TranscriptDeduper()
    private let eventMerger = EventMerger()

    var summaryModelDisplay: String {
        "\(settings.llmBackend.rawValue) / \(settings.activeLLMModelID)"
    }

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GijirokuTaker/Sessions", isDirectory: true)
        self.sessionStore = FileSessionStore(directory: dir)
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        sessionId = UUID()
        sessionStartedAt = .now
        statusMessage = L10n.string("status.starting")
        fputs("[GijirokuTaker] startRecording backend=\(settings.llmBackend.rawValue)\n", stderr)

        // Build per-session engines from current settings so that changes apply
        // without restarting the app.
        let llm: any LLMClient
        switch settings.llmBackend {
        case .ollama:
            let llmBaseURL = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
            llm = OllamaClient(baseURL: llmBaseURL)
            fputs("[GijirokuTaker] Ollama client created baseURL=\(llmBaseURL)\n", stderr)
        case .mlx:
            llm = MLXClient { [weak self] progress in
                // fraction >= 0.99 (cache hit / DL 完了) では DL バッジを表示しない。
                // 実 DL 中だけ「モデルDL中」を見せる方が UX として誤誘導が少ない。
                guard progress.fraction < 0.99 else { return }
                Task { @MainActor in
                    self?.summaryProgress = .modelDownloading(
                        modelID: progress.modelID,
                        fraction: progress.fraction
                    )
                }
            }
            fputs("[GijirokuTaker] MLX client created\n", stderr)
        }
        self.client = llm

        let llmModelID = settings.activeLLMModelID
        let language = settings.whisperLanguage == "auto" ? "auto" : (settings.whisperLanguage == "ja" ? "Japanese" : "English")

        // Resolve summary style: builtin → user → project (session level
        // doesn't exist yet for an in-progress recording).
        let project = LibraryModel.shared.activeProjectID.flatMap { id in
            LibraryModel.shared.projects.first(where: { $0.id == id })
        }
        let resolvedStyle = SummaryStyle.resolved(
            user: settings.userSummaryStyle,
            project: project?.summaryStyle,
            session: nil
        )

        let summaryConfig = SummaryEngine.Config(
            model: llmModelID,
            language: language,
            style: resolvedStyle
        )
        let summaryEngine = SummaryEngine(client: llm, config: summaryConfig)
        self.summaryEngine = summaryEngine

        let eventExtractor = EventExtractor(client: llm, config: .init(model: llmModelID, style: resolvedStyle))
        self.eventExtractor = eventExtractor

        let whisperLanguageRaw = settings.whisperLanguage
        let whisperLang = (whisperLanguageRaw == "auto") ? nil : whisperLanguageRaw
        let transcription = WhisperTranscription(
            config: .init(
                modelName: settings.whisperModel,
                language: whisperLang ?? "ja",
                diarizationEnabled: settings.diarizationEnabled
            )
        )
        self.transcriptionEngine = transcription

        transcript.removeAll()
        summary = CumulativeSummary()
        events.removeAll()
        pendingForSummary.removeAll()

        startSummaryLoop()
        startAudioPipeline()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        summaryLoopTask?.cancel()
        summaryLoopTask = nil
        audioPumpTask?.cancel()
        audioPumpTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        Task { [captureEngine] in await captureEngine?.stop() }
        captureEngine = nil
        statusMessage = L10n.string("status.saving")
        Task { await self.persistFinalSession() }
    }

    func append(segment: TranscriptSegment) {
        let outcome = transcriptDeduper.merge(segment, into: &transcript)
        switch outcome {
        case .appended:
            // 新規 → サマリ用にも積む
            pendingForSummary.append(segment)
        case .replaced(let previousID):
            // 既存セグメントが上書きされた → サマリ用 buffer 内の同じ id を新しい text に更新
            if let merged = transcript.first(where: { $0.id == previousID }),
               let pIdx = pendingForSummary.firstIndex(where: { $0.id == previousID }) {
                pendingForSummary[pIdx] = merged
            }
        case .ignored:
            break
        }
    }

    private func startSummaryLoop() {
        let interval = settings.summaryUpdateInterval
        summaryLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await self?.flushSummaryWindow()
            }
        }
    }

    private func flushSummaryWindow() async {
        let segments = pendingForSummary
        pendingForSummary.removeAll()
        guard !segments.isEmpty else {
            logger.info("flushSummaryWindow: no pending segments")
            return
        }
        guard let summaryEngine, let eventExtractor else {
            return
        }
        logger.info("flushSummaryWindow: requesting summary for \(segments.count, privacy: .public) segments")
        statusMessage = L10n.string("status.recording")
        summaryProgress = .summarizing(segmentCount: segments.count)
        do {
            // 直列に呼ぶ: 同じ LLM client を使うので並列化しても結局逐次実行になり、
            // むしろ進捗を 1 ステップずつ正確に出せる方が UX が良い。
            let updatedSummary = try await summaryEngine.ingest(newSegments: segments)
            summaryProgress = .extractingEvents(segmentCount: segments.count)
            let newEvents = try await eventExtractor.extract(from: segments)
            summary = updatedSummary
            let beforeCount = events.count
            eventMerger.merge(newEvents, into: &events)
            let added = events.count - beforeCount
            let updated = newEvents.count - added
            logger.info("flushSummaryWindow: sections=\(updatedSummary.sections.count, privacy: .public) events new=\(added, privacy: .public) updated=\(updated, privacy: .public)")
            summaryProgress = .done(at: .now, sections: updatedSummary.sections.count, events: events.count)
        } catch {
            logger.error("Summary error: \(error.localizedDescription, privacy: .public)")
            summaryProgress = .failed(message: error.localizedDescription)
        }
    }

    /// Resets the cumulative summary and re-runs the LLM against the entire
    /// transcript collected so far. Useful when the model / language settings
    /// changed mid-session, or the first pass produced an incomplete summary.
    func regenerateSummary() {
        guard !transcript.isEmpty else { return }
        Task {
            await self.runRegeneration()
        }
    }

    private func runRegeneration() async {
        guard let summaryEngine, let eventExtractor else { return }
        let segments = transcript
        logger.info("regenerateSummary: full transcript \(segments.count, privacy: .public) segments")
        await summaryEngine.reset()
        summary = CumulativeSummary()
        events.removeAll()
        pendingForSummary.removeAll()
        summaryProgress = .summarizing(segmentCount: segments.count)
        do {
            let updatedSummary = try await summaryEngine.ingest(newSegments: segments)
            summaryProgress = .extractingEvents(segmentCount: segments.count)
            let newEvents = try await eventExtractor.extract(from: segments)
            summary = updatedSummary
            eventMerger.merge(newEvents, into: &events)
            summaryProgress = .done(at: .now, sections: updatedSummary.sections.count, events: events.count)
        } catch {
            logger.error("regenerateSummary error: \(error.localizedDescription, privacy: .public)")
            summaryProgress = .failed(message: error.localizedDescription)
        }
    }

    private func startAudioPipeline() {
        let preferredUID = settings.preferredInputDeviceUID.isEmpty ? nil : settings.preferredInputDeviceUID
        let engine = AudioCaptureEngine(config: .init(
            captureSystem: settings.captureSystemAudio,
            captureMicrophone: settings.captureMicrophone,
            preferredInputDeviceUID: preferredUID,
            enableVoiceProcessing: settings.voiceProcessingEnabled
        ))
        captureEngine = engine
        guard let transcriber = transcriptionEngine else { return }

        audioPumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.statusMessage = L10n.string("status.starting_audio")
                let audioStream = try await engine.start()
                self.statusMessage = L10n.string("status.loading_model")
                let segmentStream = transcriber.transcribe(audioStream)
                self.statusMessage = L10n.string("status.recording")
                for await segment in segmentStream {
                    self.append(segment: segment)
                    if Task.isCancelled { break }
                }
            } catch {
                self.statusMessage = L10n.format("status.capture_error_format", error.localizedDescription)
                self.logger.error("Capture error: \(error.localizedDescription, privacy: .public)")
            }
        }

        waveformTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let waveStream = await engine.subscribeWaveform()
            for await chunk in waveStream {
                let rms = AppModel.computeRMS(chunk.samples)
                switch chunk.source {
                case .microphone:
                    self.micWaveform.ingest(rms)
                case .system:
                    self.systemWaveform.ingest(rms)
                }
                if Task.isCancelled { break }
            }
        }
    }

    private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    private func persistFinalSession() async {
        await flushSummaryWindow()
        summaryProgress = .generatingTitle
        let title = await generateTitle()
        let projectID = LibraryModel.shared.activeProjectID
        let session = Session(
            id: sessionId,
            projectId: projectID,
            title: title,
            startedAt: sessionStartedAt,
            endedAt: .now,
            transcript: transcript,
            summary: summary,
            events: events
        )
        do {
            try sessionStore.save(session)
            statusMessage = L10n.format("status.saved_format", String(session.id.uuidString.prefix(8)))
            summaryProgress = .done(at: .now, sections: summary.sections.count, events: events.count)
            LibraryModel.shared.reload()
        } catch {
            statusMessage = L10n.format("status.summary_error_format", error.localizedDescription)
            summaryProgress = .failed(message: error.localizedDescription)
        }
    }

    /// Generates a short meeting title via the LLM and prefixes it with the
    /// session date (yyyy-MM-dd). The date is always present even when the
    /// LLM call fails, per the user requirement.
    private func generateTitle() async -> String {
        let datePrefix = Self.dateFormatter.string(from: sessionStartedAt)
        let fallback = L10n.string("meeting.default_title")
        guard !transcript.isEmpty, let client else {
            return "\(datePrefix) \(fallback)"
        }
        // Cap the prompt: send a head and tail snippet so the model has both
        // the opening topic and any concluding decisions to work from.
        let texts = transcript.map { $0.text }
        let head = texts.prefix(20).joined(separator: " ")
        let tail = texts.count > 20 ? "\n…\n" + texts.suffix(10).joined(separator: " ") : ""
        let snippet = String((head + tail).prefix(2_000))
        let messages: [LLMMessage] = [
            .init(role: .system, content: """
            あなたは会議録の編集者です。次の transcript 抜粋を読み、20文字以内で会議内容を表す簡潔なタイトルを 1 つだけ日本語で出力してください。タイトル以外（前置き・括弧・引用符・改行・説明）は一切出力禁止。
            """),
            .init(role: .user, content: snippet),
        ]
        do {
            let raw = try await client.chat(
                model: settings.activeLLMModelID,
                messages: messages,
                format: .text
            )
            let cleaned = sanitizeTitle(raw)
            return cleaned.isEmpty ? "\(datePrefix) \(fallback)" : "\(datePrefix) \(cleaned)"
        } catch {
            logger.error("Title generation failed: \(error.localizedDescription, privacy: .public)")
            return "\(datePrefix) \(fallback)"
        }
    }

    private func sanitizeTitle(_ raw: String) -> String {
        // 1) <think>...</think> ブロック除去 (reasoning models 対策)
        var t = SummaryEngine.stripThinkBlocks(raw)
        // 2) 通常の clean up
        t = t
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "「", with: "")
            .replacingOccurrences(of: "」", with: "")
            .replacingOccurrences(of: "『", with: "")
            .replacingOccurrences(of: "』", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        // 先頭の "タイトル:" 等の prefix を剥がす
        for prefix in ["タイトル:", "タイトル：", "Title:", "title:"] {
            if t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if t.count > 40 { t = String(t.prefix(40)) }
        return t
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
