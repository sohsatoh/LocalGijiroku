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
    @Published var statusMessage: String = "Idle"
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
        statusMessage = "Starting..."
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
                Task { @MainActor in
                    self?.statusMessage = "Loading LLM... \(Int(progress.fraction * 100))%"
                }
            }
            fputs("[GijirokuTaker] MLX client created\n", stderr)
        }
        self.client = llm

        let llmModelID = settings.activeLLMModelID
        let summaryConfig = SummaryEngine.Config(
            model: llmModelID,
            language: settings.whisperLanguage == "auto" ? "auto" : (settings.whisperLanguage == "ja" ? "Japanese" : "English")
        )
        let summaryEngine = SummaryEngine(client: llm, config: summaryConfig)
        self.summaryEngine = summaryEngine

        let eventExtractor = EventExtractor(client: llm, config: .init(model: llmModelID))
        self.eventExtractor = eventExtractor

        let language = settings.whisperLanguage
        let whisperLang = (language == "auto") ? nil : language
        let transcription = WhisperTranscription(
            config: .init(
                modelName: settings.whisperModel,
                language: whisperLang ?? "ja"
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
        statusMessage = "Saving..."
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
        fputs("[GijirokuTaker] flushSummaryWindow segments=\(segments.count)\n", stderr)
        guard !segments.isEmpty else {
            logger.info("flushSummaryWindow: no pending segments")
            return
        }
        guard let summaryEngine, let eventExtractor else {
            fputs("[GijirokuTaker] flushSummaryWindow: summaryEngine or eventExtractor is nil\n", stderr)
            return
        }
        fputs("[GijirokuTaker] flushSummaryWindow: invoking ingest()\n", stderr)
        logger.info("flushSummaryWindow: requesting summary for \(segments.count, privacy: .public) segments")
        statusMessage = "Summarizing..."
        do {
            async let summaryResult = summaryEngine.ingest(newSegments: segments)
            async let eventsResult = eventExtractor.extract(from: segments)
            let (updatedSummary, newEvents) = try await (summaryResult, eventsResult)
            summary = updatedSummary
            let beforeCount = events.count
            eventMerger.merge(newEvents, into: &events)
            let added = events.count - beforeCount
            let updated = newEvents.count - added
            logger.info("flushSummaryWindow: sections=\(updatedSummary.sections.count, privacy: .public) events new=\(added, privacy: .public) updated=\(updated, privacy: .public)")
            statusMessage = "Recording..."
        } catch {
            logger.error("Summary error: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Summary error: \(error.localizedDescription)"
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
                self.statusMessage = "Starting audio capture..."
                let audioStream = try await engine.start()
                self.statusMessage = "Loading model... (first run may take a while)"
                let segmentStream = transcriber.transcribe(audioStream)
                self.statusMessage = "Recording..."
                for await segment in segmentStream {
                    self.append(segment: segment)
                    if Task.isCancelled { break }
                }
            } catch {
                self.statusMessage = "Capture error: \(error.localizedDescription)"
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
        let projectID = LibraryModel.shared.activeProjectID
        let session = Session(
            id: sessionId,
            projectId: projectID,
            title: defaultTitle(),
            startedAt: sessionStartedAt,
            endedAt: .now,
            transcript: transcript,
            summary: summary,
            events: events
        )
        do {
            try sessionStore.save(session)
            statusMessage = "Saved \(session.id.uuidString.prefix(8))"
            LibraryModel.shared.reload()
        } catch {
            statusMessage = "Save error: \(error.localizedDescription)"
        }
    }

    private func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(formatter.string(from: sessionStartedAt))"
    }
}
