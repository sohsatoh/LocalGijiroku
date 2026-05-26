import Foundation
import OSLog
import GijirokuCore
import WhisperKit
import SpeakerKit

// WhisperKit also defines a public `AudioChunk` struct that collides with
// GijirokuCore.AudioChunk. We refer to ours by module-qualified name throughout
// this file to avoid ambiguity.
public actor WhisperTranscription: TranscriptionEngine {
    public struct Config: Sendable {
        public let modelName: String
        public let language: String
        public let windowSeconds: TimeInterval
        public let inferenceInterval: TimeInterval
        public let diarizationEnabled: Bool
        /// When true, hand WhisperKit an EnergyVAD so it splits each 25 s
        /// rolling window into voiced sub-regions before transcribing. This
        /// produces segment boundaries that land on natural pauses instead
        /// of mid-utterance — the main complaint about Whisper's default
        /// chunking for meeting use.
        public let vadEnabled: Bool
        /// Energy threshold for the VAD (0 = always voiced, 1 = never).
        /// WhisperKit's default is 0.02. Quiet meeting audio sometimes needs
        /// a lower value (e.g. 0.01) to catch soft speech; noisy mic input
        /// benefits from a higher value to filter background hiss.
        public let vadEnergyThreshold: Float

        public init(
            modelName: String = "large-v3-v20240930_626MB",
            language: String = "ja",
            windowSeconds: TimeInterval = 25,
            inferenceInterval: TimeInterval = 5,
            diarizationEnabled: Bool = false,
            vadEnabled: Bool = true,
            vadEnergyThreshold: Float = 0.02
        ) {
            self.modelName = modelName
            self.language = language
            self.windowSeconds = windowSeconds
            self.inferenceInterval = inferenceInterval
            self.diarizationEnabled = diarizationEnabled
            self.vadEnabled = vadEnabled
            self.vadEnergyThreshold = vadEnergyThreshold
        }
    }

    fileprivate struct SourceBuffer {
        let source: AudioSource
        let sampleRate: Double = 16_000
        fileprivate var samples: [Float] = []
        fileprivate var startedAt: Date?
        fileprivate var droppedSeconds: TimeInterval = 0

        fileprivate init(source: AudioSource) {
            self.source = source
        }

        var totalSamples: Int { samples.count }

        mutating func append(_ chunk: GijirokuCore.AudioChunk) {
            if samples.isEmpty, startedAt == nil { startedAt = chunk.startTime }
            samples.append(contentsOf: chunk.samples)
        }

        func recentSamples(seconds: TimeInterval) -> [Float] {
            let needed = Int(seconds * sampleRate)
            if samples.count <= needed { return samples }
            return Array(samples.suffix(needed))
        }

        func startTime(forTailLength sliceLength: Int) -> Date {
            let started = startedAt ?? Date()
            let offsetFromStarted = max(0, samples.count - sliceLength)
            return started.addingTimeInterval(droppedSeconds + Double(offsetFromStarted) / sampleRate)
        }

        mutating func dropOlderThan(seconds: TimeInterval) {
            let keep = Int(seconds * sampleRate)
            if samples.count > keep {
                let dropCount = samples.count - keep
                samples.removeFirst(dropCount)
                droppedSeconds += Double(dropCount) / sampleRate
            }
        }
    }

    private static let hallucinationPatterns: Set<String> = [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございました。",
        "ご視聴ありがとうございます",
        "ご視聴ありがとうございます。",
        "ご清聴ありがとうございました",
        "ご清聴ありがとうございました。",
        "ありがとうございました",
        "ありがとうございました。",
        "ありがとうございます",
        "ありがとうございます。",
        "はい",
        "はい。",
        "ん",
        "Thanks for watching!",
        "Thank you for watching.",
        "Thank you.",
    ]

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "WhisperTranscription")
    private let config: Config
    private var whisper: WhisperKit?
    private var speakerKit: SpeakerKit?
    /// Cross-window stable label assigner. Resets per session inside
    /// `transcribe(_:)`.
    private let speakerTracker = SpeakerTracker()
    /// Rolling per-source audio buffers. Lifted out of `run()` so external
    /// callers (AppModel) can clear them via `clearSource(_:)` when the
    /// user toggles a source off mid-recording — otherwise the buffer
    /// still holds the last ~25 s of audio and every 5-s inference cycle
    /// keeps transcribing it.
    private var buffers: [AudioSource: SourceBuffer] = [
        .microphone: SourceBuffer(source: .microphone),
        .system: SourceBuffer(source: .system),
    ]

    public init(config: Config = .init()) {
        self.config = config
    }

    /// Drop accumulated audio for the given source. Called by AppModel
    /// immediately after the AudioCaptureEngine has been told to stop a
    /// source, so the inference loop doesn't keep re-transcribing the
    /// last 25 s of audio that's still sitting in the buffer.
    public func clearSource(_ source: AudioSource) {
        buffers[source] = SourceBuffer(source: source)
        fputs("[WhisperTranscription] cleared \(source.rawValue) buffer\n", stderr)
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let whisper { return whisper }
        logger.info("Loading WhisperKit model=\(self.config.modelName, privacy: .public) (downloads on first use)...")
        // Hand WhisperKit an EnergyVAD when enabled so it can pre-segment the
        // rolling audio window by silence — yields segment boundaries that
        // align with speech pauses instead of Whisper's internal token
        // heuristics. EnergyVAD is cheap and configured via energyThreshold.
        let vad: VoiceActivityDetector? = config.vadEnabled
            ? EnergyVAD(energyThreshold: config.vadEnergyThreshold)
            : nil
        let kit = try await WhisperKit(WhisperKitConfig(
            model: config.modelName,
            voiceActivityDetector: vad
        ))
        whisper = kit
        if config.vadEnabled {
            fputs("[WhisperTranscription] VAD enabled (energyThreshold=\(config.vadEnergyThreshold))\n", stderr)
        } else {
            fputs("[WhisperTranscription] VAD disabled\n", stderr)
        }
        logger.info("WhisperKit loaded.")
        return kit
    }

    /// Lazily loads SpeakerKit. Returns nil (with a logged error) if loading
    /// fails so transcription can still proceed without diarization.
    private func ensureSpeakerLoaded() async -> SpeakerKit? {
        if let speakerKit { return speakerKit }
        do {
            fputs("[WhisperTranscription] loading SpeakerKit...\n", stderr)
            logger.info("Loading SpeakerKit (pyannote, ~30MB on first use)...")
            let kit = try await SpeakerKit()
            speakerKit = kit
            logger.info("SpeakerKit loaded.")
            fputs("[WhisperTranscription] SpeakerKit loaded\n", stderr)
            return kit
        } catch {
            logger.error("SpeakerKit load failed: \(error.localizedDescription, privacy: .public)")
            fputs("[WhisperTranscription] SpeakerKit load failed: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    public nonisolated func transcribe(_ chunks: AsyncStream<GijirokuCore.AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            Task {
                await self.speakerTracker.reset()
                await self.run(chunks: chunks, output: continuation)
            }
        }
    }

    private func run(
        chunks: AsyncStream<GijirokuCore.AudioChunk>,
        output: AsyncStream<TranscriptSegment>.Continuation
    ) async {
        do {
            _ = try await ensureLoaded()
        } catch {
            logger.error("WhisperKit load failed: \(error.localizedDescription, privacy: .public)")
            output.finish()
            return
        }

        // Reset the actor-owned buffers for this transcription session
        // (resume after pause / new recording start). lastInferenceAt is
        // a local because nothing outside the loop needs it.
        buffers = [
            .microphone: SourceBuffer(source: .microphone),
            .system: SourceBuffer(source: .system),
        ]
        var lastInferenceAt = Date.distantPast

        var chunkCount = 0
        for await chunk in chunks {
            // Subscript-and-mutate the actor's dictionary in place. Without
            // pulling the buffer into a local var we'd be mutating a copy
            // and discarding it (Swift Dictionary value-type semantics).
            if var buffer = buffers[chunk.source] {
                buffer.append(chunk)
                buffers[chunk.source] = buffer
            }
            chunkCount += 1
            if chunkCount.isMultiple(of: 10) {
                let mic = buffers[.microphone]?.totalSamples ?? 0
                let sys = buffers[.system]?.totalSamples ?? 0
                logger.info("Chunk #\(chunkCount, privacy: .public) buffered samples mic=\(mic, privacy: .public) sys=\(sys, privacy: .public)")
            }

            let now = Date()
            if now.timeIntervalSince(lastInferenceAt) >= config.inferenceInterval {
                lastInferenceAt = now
                for source in [AudioSource.microphone, AudioSource.system] {
                    guard var buffer = buffers[source], buffer.totalSamples > Int(buffer.sampleRate) else { continue }
                    let samples = buffer.recentSamples(seconds: config.windowSeconds)
                    let bufferStart = buffer.startTime(forTailLength: samples.count)
                    logger.info("Inferencing \(String(describing: source), privacy: .public) samples=\(samples.count, privacy: .public)")
                    await runInference(
                        source: source,
                        samples: samples,
                        bufferStartedAt: bufferStart,
                        output: output
                    )
                    buffer.dropOlderThan(seconds: config.windowSeconds)
                    buffers[source] = buffer
                }
            }
        }
        output.finish()
    }

    private func runInference(
        source: AudioSource,
        samples: [Float],
        bufferStartedAt: Date,
        output: AsyncStream<TranscriptSegment>.Continuation
    ) async {
        guard let whisper else { return }
        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: config.language,
                temperature: 0,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                suppressBlank: true
            )
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            let totalSegments = results.reduce(0) { $0 + $1.segments.count }
            logger.info("\(String(describing: source), privacy: .public) result: results=\(results.count, privacy: .public) segments=\(totalSegments, privacy: .public)")

            // Optionally run speaker diarization over the same audio window.
            // Two-step labeling:
            //   1. Local (per-window) diarization gives us
            //      [(start, end, "speakerId(0)"), ...]
            //   2. SpeakerTracker maps those window-local labels into stable
            //      cross-window labels ("Speaker 1", "Speaker 2", ...) by
            //      finding the historical stable span that has maximum time
            //      overlap with the new local span.
            let speakerSpans = await diarizationSpans(samples: samples)
            let labelMap: [String: String]
            if speakerSpans.isEmpty {
                labelMap = [:]
            } else {
                let absoluteSpans = speakerSpans.map { span in
                    SpeakerTracker.AbsoluteSpan(
                        start: bufferStartedAt.addingTimeInterval(span.start),
                        end: bufferStartedAt.addingTimeInterval(span.end),
                        localLabel: span.speaker
                    )
                }
                labelMap = await speakerTracker.resolve(spans: absoluteSpans)
            }

            for result in results {
                for seg in result.segments {
                    let raw: String = seg.text
                    let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if Self.hallucinationPatterns.contains(text) { continue }
                    let segStart = bufferStartedAt.addingTimeInterval(TimeInterval(seg.start))
                    let segEnd = bufferStartedAt.addingTimeInterval(TimeInterval(seg.end))
                    let midpoint = (Double(seg.start) + Double(seg.end)) / 2
                    let localSpeaker = Self.speaker(at: midpoint, in: speakerSpans)
                    let stableSpeaker = localSpeaker.flatMap { labelMap[$0] } ?? localSpeaker
                    let transcript = TranscriptSegment(
                        source: source,
                        speaker: stableSpeaker,
                        text: text,
                        startTime: segStart,
                        endTime: segEnd,
                        isFinal: false
                    )
                    let preview = text.prefix(60)
                    logger.info("\(String(describing: source), privacy: .public) seg: \"\(String(preview), privacy: .public)\" speaker=\(stableSpeaker ?? "-", privacy: .public)")
                    output.yield(transcript)
                }
            }
        } catch {
            logger.error("Inference failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A `(start, end, speaker)` span produced by SpeakerKit. Callers map
    /// transcription segments into speakers by checking which span their
    /// midpoint falls into.
    fileprivate struct SpeakerSpan: Sendable {
        let start: Double
        let end: Double
        let speaker: String
    }

    /// Runs SpeakerKit diarization (when enabled and loaded) and returns the
    /// resulting list of speaker time spans. Returns empty on failure / when
    /// disabled so callers fall back to non-attributed segments.
    private func diarizationSpans(samples: [Float]) async -> [SpeakerSpan] {
        guard config.diarizationEnabled else { return [] }
        guard let speakerKit = await ensureSpeakerLoaded() else { return [] }
        do {
            let diarization = try await speakerKit.diarize(audioArray: samples)
            // `diarization.segments` exposes (start, end, speaker) entries.
            // Convert to our internal Sendable representation.
            let spans = diarization.segments.map { seg in
                SpeakerSpan(
                    start: Double(seg.startTime),
                    end: Double(seg.endTime),
                    speaker: String(describing: seg.speaker)
                )
            }
            logger.info("Diarization: \(diarization.speakerCount, privacy: .public) speaker(s), \(spans.count, privacy: .public) span(s)")
            return spans
        } catch {
            logger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Returns the speaker label whose span contains `time` (in seconds
    /// relative to the audio buffer), or nil if none.
    fileprivate static func speaker(at time: Double, in spans: [SpeakerSpan]) -> String? {
        spans.first(where: { time >= $0.start && time <= $0.end })?.speaker
    }
}
