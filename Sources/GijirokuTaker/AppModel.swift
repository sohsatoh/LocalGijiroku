import Foundation
import OSLog
import SwiftUI
import GijirokuCore
import GijirokuLLM

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "AppModel")

    @Published var isRecording: Bool = false
    /// True while recording is paused (audio engines stopped but session
    /// state — transcript, summary, events, sessionId — is preserved).
    /// `isRecording` stays true in this state; only `isPaused` differentiates.
    @Published var isPaused: Bool = false
    @Published var transcript: [TranscriptSegment] = []
    @Published var summary: CumulativeSummary = CumulativeSummary()
    @Published var events: [MeetingEvent] = []
    @Published var statusMessage: String = L10n.string("status.idle")
    @Published var summaryProgress: SummaryProgress = .idle
    @Published var micWaveform = WaveformChannelState()
    @Published var systemWaveform = WaveformChannelState()
    /// Per-session whisper language override. `nil` → use
    /// `SettingsModel.shared.whisperLanguage`. Once the user explicitly picks a
    /// language for an upcoming recording, the choice sticks across sessions
    /// (within this app run) until they reset it. Not persisted to disk —
    /// the persistent default lives in Settings.
    @Published var languageOverride: String? = nil

    /// The whisper language that will be used on next Start.
    var effectiveLanguage: String {
        languageOverride ?? settings.whisperLanguage
    }

    private let settings: SettingsModel = .shared
    private let sessionStore: FileSessionStore
    /// Separate on-disk store for in-progress recordings. Autosaved every
    /// 30 s and on every transcript append so a crash / kill / power loss
    /// during a long meeting doesn't take the whole transcript with it.
    /// Drafts get promoted to `sessionStore` on Stop, or recovered on the
    /// next launch if Stop never happened.
    private let draftStore: FileSessionStore

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
    private var autosaveTask: Task<Void, Never>?
    private let transcriptDeduper = TranscriptDeduper()
    private let eventMerger = EventMerger()

    var summaryModelDisplay: String {
        "\(settings.llmBackend.rawValue) / \(settings.activeLLMModelID)"
    }

    /// Whether diarization is configured to run for the current session.
    /// Forwards settings so SwiftUI views don't need to access SettingsModel.
    var diarizationEnabled: Bool {
        settings.diarizationEnabled
    }

    /// Number of distinct (non-nil) speaker labels currently in transcript.
    /// Used by the live recording view's "Speakers: N detected" indicator.
    var distinctSpeakerCount: Int {
        var seen = Set<String>()
        for seg in transcript {
            if let s = seg.speaker, !s.isEmpty, !s.lowercased().contains("nomatch") {
                seen.insert(s)
            }
        }
        return seen.count
    }

    /// The confirmed-only view of the live transcript. Everything that goes
    /// to disk (drafts, final session) or the LLM pipeline (summary,
    /// regenerate, title) must use this — unconfirmed segments are the
    /// rolling Whisper tail that may be rewritten on the next inference
    /// cycle, so persisting or summarizing them produces unstable output.
    private var confirmedTranscript: [TranscriptSegment] {
        transcript.filter(\.isConfirmed)
    }

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sessionsDir = appSupport.appendingPathComponent("GijirokuTaker/Sessions", isDirectory: true)
        let draftsDir = appSupport.appendingPathComponent("GijirokuTaker/Drafts", isDirectory: true)
        self.sessionStore = FileSessionStore(directory: sessionsDir)
        self.draftStore = FileSessionStore(directory: draftsDir)
        // Recover any orphaned drafts left by a previous crash / force-quit.
        // Runs synchronously so the sidebar is correct before the user sees
        // the first frame. File IO here is small (one Codable read per
        // draft) and only happens when drafts actually exist.
        recoverOrphanedDrafts()
    }

    /// Promote any in-progress recordings left in the drafts directory into
    /// the regular Sessions store. The previous launch crashed / was killed
    /// before `persistFinalSession` could run; without this we'd silently
    /// lose the entire transcript. Recovered sessions get a localized prefix
    /// on their title so the user notices them in the sidebar.
    private func recoverOrphanedDrafts() {
        let prefix = L10n.string("meeting.recovered_prefix")
        do {
            let promoted = try DraftRecovery.promoteOrphans(
                from: draftStore,
                into: sessionStore,
                recoveredPrefix: prefix
            )
            if promoted > 0 {
                fputs("[GijirokuTaker] recovered \(promoted) orphaned draft(s)\n", stderr)
            }
        } catch {
            fputs("[GijirokuTaker] draft recovery failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Persist the current in-progress recording to the drafts directory.
    /// Cheap (~1 KB per minute of transcript, one Codable encode + atomic
    /// write) and idempotent. Called periodically by the autosave loop and
    /// on every transcript append, so a crash loses at most the last few
    /// seconds of audio that hadn't yet produced a Whisper segment.
    private func persistDraft() {
        guard isRecording else { return }
        let projectID = LibraryModel.shared.activeProjectID
        let draft = Session(
            id: sessionId,
            projectId: projectID,
            title: L10n.string("meeting.in_progress_title"),
            startedAt: sessionStartedAt,
            endedAt: nil,
            // Drop the unconfirmed tail before writing — those segments
            // can still be rewritten on the next inference cycle, and the
            // recovery path treats the draft as authoritative.
            transcript: confirmedTranscript,
            summary: summary,
            events: events
        )
        do {
            try draftStore.save(draft)
        } catch {
            // Don't escalate to the user — they're recording, not the
            // moment to throw an autosave dialog. Log and let the next
            // cycle retry.
            fputs("[GijirokuTaker] draft autosave failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Background loop that periodically flushes the in-memory recording
    /// state to disk as a draft. Runs on a fixed 30-second cadence,
    /// independent of the summary loop so unrelated LLM stalls can't block
    /// the durability guarantee.
    private func startAutosaveLoop() {
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await MainActor.run { self?.persistDraft() }
            }
        }
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
                Task { @MainActor in
                    guard let self else { return }
                    // Below ~99% → real download in progress, show the
                    // determinate bar with the percentage.
                    // At or above 99% → the HuggingFace fetch is done and
                    // the weights are being mapped into memory (or the model
                    // was already cached). Switch to the indeterminate
                    // "loading" state so the bar doesn't look frozen at 98%
                    // during the multi-second memory-map step.
                    if progress.fraction < 0.99 {
                        self.summaryProgress = .modelDownloading(
                            modelID: progress.modelID,
                            fraction: progress.fraction
                        )
                    } else if case .modelDownloading = self.summaryProgress {
                        // Only transition out of the active download state;
                        // don't clobber a later `.extractingEvents` or
                        // `.summarizing` that legitimately replaced us.
                        self.summaryProgress = .modelLoading(modelID: progress.modelID)
                    }
                }
            }
            fputs("[GijirokuTaker] MLX client created\n", stderr)
        }
        self.client = llm

        let llmModelID = settings.activeLLMModelID
        let whisperLangRaw = effectiveLanguage
        let language = whisperLangRaw == "auto" ? "auto" : (whisperLangRaw == "ja" ? "Japanese" : "English")

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

        let whisperLang = (whisperLangRaw == "auto") ? nil : whisperLangRaw
        let transcription = WhisperTranscription(
            config: .init(
                modelName: settings.whisperModel,
                language: whisperLang ?? "ja",
                diarizationEnabled: settings.diarizationEnabled,
                vadEnabled: settings.vadEnabled
            )
        )
        self.transcriptionEngine = transcription

        transcript.removeAll()
        summary = CumulativeSummary()
        events.removeAll()
        pendingForSummary.removeAll()

        // Persist an empty draft immediately so the session's existence is
        // recorded on disk before any audio flows — if the app dies in the
        // first few seconds, recovery still picks up the session shell.
        persistDraft()
        startAutosaveLoop()
        startSummaryLoop()
        startAudioPipeline()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        summaryLoopTask?.cancel()
        summaryLoopTask = nil
        audioPumpTask?.cancel()
        audioPumpTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        Task { [captureEngine] in await captureEngine?.stop() }
        captureEngine = nil
        // Drop the lingering waveform levels right away so the UI visibly
        // quiets down on Stop instead of freezing at the last sample.
        micWaveform = WaveformChannelState()
        systemWaveform = WaveformChannelState()
        statusMessage = L10n.string("status.saving")
        Task { await self.persistFinalSession() }
    }

    /// Pause an in-flight recording. Tears down the audio engines and
    /// summary loop but keeps every accumulated piece of session state
    /// (transcript, summary, events, sessionId, sessionStartedAt). Resume
    /// brings the pipeline back up against the same session.
    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        summaryLoopTask?.cancel()
        summaryLoopTask = nil
        audioPumpTask?.cancel()
        audioPumpTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        Task { [captureEngine] in await captureEngine?.stop() }
        captureEngine = nil
        micWaveform = WaveformChannelState()
        systemWaveform = WaveformChannelState()
        // Flush a draft as soon as we pause — captures whatever the user has
        // so far in case they walk away from the laptop after pausing.
        persistDraft()
        statusMessage = L10n.string("status.paused")
        fputs("[GijirokuTaker] paused\n", stderr)
    }

    /// Resume a paused recording. Re-creates the audio engines + summary
    /// loop using the original session's transcription/LLM engines; any
    /// audio captured during the pause is naturally absent from transcript.
    func resumeRecording() {
        guard isRecording, isPaused else { return }
        isPaused = false
        statusMessage = L10n.string("status.recording")
        startAutosaveLoop()
        startSummaryLoop()
        startAudioPipeline()
        fputs("[GijirokuTaker] resumed\n", stderr)
    }

    /// Live-toggle the system-audio source mid-recording. Reflects the
    /// change into SettingsModel so the next session picks it up too.
    /// No-op while paused — the engine is torn down then.
    func setSystemCaptureEnabled(_ enabled: Bool) {
        settings.captureSystemAudio = enabled
        guard isRecording, !isPaused, let captureEngine else { return }
        Task {
            await captureEngine.setSystemEnabled(enabled)
            // Drop the source's rolling audio buffer so the inference loop
            // doesn't keep transcribing the last 25 s of stale audio.
            // Symmetric for both directions: on-toggle starts a fresh
            // buffer, off-toggle clears one that would otherwise persist.
            if let transcription = self.transcriptionEngine {
                await transcription.clearSource(.system)
            }
        }
        if !enabled {
            // Reset the waveform meter so the muted source visibly quiets.
            systemWaveform = WaveformChannelState()
        }
    }

    func setMicCaptureEnabled(_ enabled: Bool) {
        settings.captureMicrophone = enabled
        guard isRecording, !isPaused, let captureEngine else { return }
        Task {
            await captureEngine.setMicEnabled(enabled)
            if let transcription = self.transcriptionEngine {
                await transcription.clearSource(.microphone)
            }
        }
        if !enabled {
            micWaveform = WaveformChannelState()
        }
    }

    func append(segment: TranscriptSegment) {
        let outcome = transcriptDeduper.merge(segment, into: &transcript)
        switch outcome {
        case .appended:
            // 確定済みのみサマリ用 buffer に積む。未確定セグメントは次のサイクルで
            // 書き換えられる可能性があるので LLM パイプラインに渡さない。
            // 後で `.replaced` で confirmed=true へ昇格した瞬間にここに入る。
            if segment.isConfirmed {
                pendingForSummary.append(segment)
            }
        case .replaced(let previousID):
            // 既存セグメントが上書きされた → サマリ用 buffer の同じ id を最新版に置換。
            // 未確定 → 確定への昇格でも同じ枝に入るので、初めて pendingForSummary に
            // 追加されるのはこの瞬間。append しているわけではないので findIndex で
            // 既存があれば更新、無ければ新規追加。
            guard let merged = transcript.first(where: { $0.id == previousID }) else { break }
            if let pIdx = pendingForSummary.firstIndex(where: { $0.id == previousID }) {
                if merged.isConfirmed {
                    pendingForSummary[pIdx] = merged
                } else {
                    // Downgrade is impossible (deduper's confirmation is sticky)
                    // so this branch only fires when the existing entry was
                    // already confirmed — keep it.
                    pendingForSummary[pIdx] = merged
                }
            } else if merged.isConfirmed {
                pendingForSummary.append(merged)
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
            // Append-only delta: the LLM sees only the existing section
            // TITLES + the new transcript fragment and returns just the
            // bullets to add. Keeps per-turn cost roughly constant — Stop
            // runs a full-pass regenerate that polishes the final saved
            // summary.
            var updatedSummary = try await summaryEngine.appendDelta(newSegments: segments)
            // Consolidate the resulting summary so semantic duplicates
            // and redundant bullets don't pile up across turns. Cheap
            // (no transcript involved); the engine skips early when the
            // summary is small enough that consolidation has nothing to
            // do. Falls back to the delta-only summary on parse failure.
            do {
                updatedSummary = try await summaryEngine.consolidate()
            } catch {
                logger.error("consolidate failed (keeping delta summary): \(error.localizedDescription, privacy: .public)")
            }
            summaryProgress = .extractingEvents(segmentCount: segments.count)
            // Pass the current still-open events so the LLM can mark them
            // resolved when the new fragment contains an answer / outcome.
            // Without this, a question extracted in turn N can never be
            // closed by an answer that arrives in turn N+1.
            let newEvents = try await eventExtractor.extract(
                from: segments,
                openEvents: events
            )
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
        // Snapshot to disk now that summary + events are in their freshest
        // state — the autosave loop runs on its own 30 s cadence but
        // catching the moment right after a successful LLM turn means a
        // crash now still preserves the LLM work the user just paid for.
        persistDraft()
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
        // Use the confirmed-only view — the rolling unconfirmed tail would
        // change the LLM's output between turns and produce flaky summaries.
        let segments = confirmedTranscript
        logger.info("regenerateSummary: full transcript \(segments.count, privacy: .public) segments")
        summary = CumulativeSummary()
        events.removeAll()
        pendingForSummary.removeAll()
        summaryProgress = .summarizing(segmentCount: segments.count)
        do {
            // Full-pass regenerate: the engine drops the accumulated
            // delta-built summary and produces a fresh one-shot summary
            // over the entire transcript. Same path Stop / the saved-
            // session "Re-summarize" button take.
            let updatedSummary = try await summaryEngine.regenerate(transcript: segments)
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
            preferredInputDeviceUID: preferredUID
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
        // From here on the recording is stopped, so the unconfirmed tail
        // will never get a chance to be promoted by a later inference
        // pass. Drop it once for the rest of the function so the saved
        // session and the final regenerate both see the same clean view.
        let finalTranscript = confirmedTranscript
        // Replace the delta-built running summary with a fresh full-pass
        // summary over the entire transcript. The recording-time deltas
        // are cheap but only see one window at a time; the full pass can
        // restructure / merge / promote bullets across the whole meeting
        // so the saved artifact is the polished Notion-style output.
        if let summaryEngine, !finalTranscript.isEmpty {
            summaryProgress = .summarizing(segmentCount: finalTranscript.count)
            do {
                summary = try await summaryEngine.regenerate(transcript: finalTranscript)
            } catch {
                logger.error("Final regenerate failed (keeping delta summary): \(error.localizedDescription, privacy: .public)")
            }
        }
        summaryProgress = .generatingTitle
        let title = await generateTitle(transcript: finalTranscript)
        // Honor the user's explicit pre-selection. Only auto-classify when
        // the user hadn't already filed the recording under a project.
        let preselectedID = LibraryModel.shared.activeProjectID
        let projectID: UUID?
        if let preselectedID {
            projectID = preselectedID
        } else {
            projectID = await classifyIntoExistingProject(title: title)
        }
        let session = Session(
            id: sessionId,
            projectId: projectID,
            title: title,
            startedAt: sessionStartedAt,
            endedAt: .now,
            transcript: finalTranscript,
            summary: summary,
            events: events
        )
        do {
            try sessionStore.save(session)
            // Final save succeeded — the draft is now redundant and would
            // otherwise be re-promoted as a "[Recovered]" duplicate on the
            // next launch. Best-effort delete; if it fails for some reason
            // the recovery path is idempotent (the dedup key is sessionId,
            // which matches the just-saved session and will be filtered
            // when recovery sees an already-saved id — but to be safe we
            // still try to remove the file).
            try? draftStore.delete(id: session.id)
            statusMessage = L10n.format("status.saved_format", String(session.id.uuidString.prefix(8)))
            summaryProgress = .done(at: .now, sections: summary.sections.count, events: events.count)
            LibraryModel.shared.reload()
            // Hand the user off to the freshly-saved session so they see the
            // result, and reset the live workspace so the next Start begins
            // from a clean state instead of looking like the previous recording
            // is still "going".
            LibraryModel.shared.selection = [.session(session.id)]
            resetLiveWorkspace()
        } catch {
            statusMessage = L10n.format("status.summary_error_format", error.localizedDescription)
            summaryProgress = .failed(message: error.localizedDescription)
        }
    }

    /// Clears the in-memory recording state. Called after a session has been
    /// persisted to disk so re-entering the live view doesn't display the
    /// previous meeting's transcript / summary / events.
    private func resetLiveWorkspace() {
        transcript.removeAll()
        summary = CumulativeSummary()
        events.removeAll()
        pendingForSummary.removeAll()
    }

    /// Picks the best-matching existing project for the just-recorded
    /// session. Returns `nil` (i.e. leave the session unfiled) when there
    /// are no candidate projects, when the summary is empty, when the LLM
    /// returns "none", or on any error — auto-classification is best-effort
    /// and must not break the save path.
    private func classifyIntoExistingProject(title: String) async -> UUID? {
        let projects = LibraryModel.shared.projects
        guard !projects.isEmpty else { return nil }
        guard !summary.sections.isEmpty else { return nil }
        guard let client else { return nil }

        summaryProgress = .classifyingProject
        let candidates = projects.map { p in
            ProjectClassifier.Candidate(id: p.id, name: p.name, note: p.note)
        }
        let language: String = {
            switch effectiveLanguage {
            case "ja": return "Japanese"
            case "en": return "English"
            default: return "auto"
            }
        }()
        let classifier = ProjectClassifier(
            client: client,
            config: .init(model: settings.activeLLMModelID, language: language)
        )
        do {
            let chosen = try await classifier.classify(
                summary: summary,
                title: title,
                candidates: candidates
            )
            if let chosen, let match = projects.first(where: { $0.id == chosen }) {
                fputs("[GijirokuTaker] auto-classified into project=\(match.name)\n", stderr)
            } else {
                fputs("[GijirokuTaker] auto-classify: no matching project, leaving unfiled\n", stderr)
            }
            return chosen
        } catch {
            logger.error("ProjectClassifier failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Generates a short meeting title via the LLM and prefixes it with the
    /// session date (yyyy-MM-dd). The date is always present even when the
    /// LLM call fails, per the user requirement.
    private func generateTitle(transcript: [TranscriptSegment]) async -> String {
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
            // Title is ≤20 chars; 60 tokens is enough to express that in any
            // language plus a brief reasoning halo. Tight cap = the post-stop
            // wait time before the session lands in the sidebar.
            let raw = try await client.chat(
                model: settings.activeLLMModelID,
                messages: messages,
                format: .text,
                maxTokens: 60
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
