import Foundation
import OSLog
import GijirokuCore
import WhisperKit

// WhisperKit also defines a public `AudioChunk` struct that collides with
// GijirokuCore.AudioChunk. We refer to ours by module-qualified name throughout
// this file to avoid ambiguity.
public actor WhisperTranscription: TranscriptionEngine {
    public struct Config: Sendable {
        public let modelName: String
        public let language: String
        public let windowSeconds: TimeInterval
        public let inferenceInterval: TimeInterval

        public init(
            modelName: String = "large-v3-v20240930_626MB",
            language: String = "ja",
            windowSeconds: TimeInterval = 25,
            inferenceInterval: TimeInterval = 5
        ) {
            self.modelName = modelName
            self.language = language
            self.windowSeconds = windowSeconds
            self.inferenceInterval = inferenceInterval
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

    public init(config: Config = .init()) {
        self.config = config
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let whisper { return whisper }
        logger.info("Loading WhisperKit model=\(self.config.modelName, privacy: .public) (downloads on first use)...")
        let kit = try await WhisperKit(WhisperKitConfig(model: config.modelName))
        whisper = kit
        logger.info("WhisperKit loaded.")
        return kit
    }

    public nonisolated func transcribe(_ chunks: AsyncStream<GijirokuCore.AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            Task {
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

        var buffers: [AudioSource: SourceBuffer] = [
            .microphone: SourceBuffer(source: .microphone),
            .system: SourceBuffer(source: .system),
        ]
        var lastInferenceAt = Date.distantPast

        var chunkCount = 0
        for await chunk in chunks {
            buffers[chunk.source]?.append(chunk)
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
            for result in results {
                for seg in result.segments {
                    let raw: String = seg.text
                    let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    // Whisper は無音区間でよく出る定型句をハルシネーションしがち。除外する。
                    if Self.hallucinationPatterns.contains(text) { continue }
                    let segStart = bufferStartedAt.addingTimeInterval(TimeInterval(seg.start))
                    let segEnd = bufferStartedAt.addingTimeInterval(TimeInterval(seg.end))
                    let transcript = TranscriptSegment(
                        source: source,
                        text: text,
                        startTime: segStart,
                        endTime: segEnd,
                        isFinal: false
                    )
                    let preview = text.prefix(60)
                    logger.info("\(String(describing: source), privacy: .public) seg: \"\(String(preview), privacy: .public)\"")
                    output.yield(transcript)
                }
            }
        } catch {
            logger.error("Inference failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
