import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech
import GijirokuCore

@available(macOS 26.0, *)
public actor SpeechAnalyzerTranscription: TranscriptionEngine {
    public struct Config: Sendable {
        public let language: String
        public let speakerLabelMicrophone: Bool

        public init(language: String = "ja", speakerLabelMicrophone: Bool = true) {
            self.language = language
            self.speakerLabelMicrophone = speakerLabelMicrophone
        }
    }

    private struct SourceTiming {
        var nextSampleOffset: Int64
    }

    private enum SpeechAnalyzerTranscriptionError: LocalizedError {
        case unavailable
        case unsupportedLocale(String)
        case cannotBuildAudioBuffer

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "SpeechAnalyzer is not available on this Mac."
            case .unsupportedLocale(let identifier):
                return "SpeechAnalyzer does not support locale \(identifier)."
            case .cannotBuildAudioBuffer:
                return "Could not build an audio buffer for SpeechAnalyzer."
            }
        }
    }

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "SpeechAnalyzerTranscription")
    private let config: Config
    private let audioFormat: AVAudioFormat

    public init(config: Config = .init()) {
        self.config = config
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    public func preload() async throws {
        let transcriber = try await makeTranscriber()
        try await prepareAssets(for: transcriber)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .utility, modelRetention: .lingering)
        )
        try await analyzer.prepareToAnalyze(in: audioFormat)
        logger.info("SpeechAnalyzer prepared locale=\(self.localeIdentifier, privacy: .public)")
    }

    public func clearSource(_ source: AudioSource) async {
        // SpeechAnalyzer consumes a live AsyncSequence directly. Once a source
        // is toggled off, AppModel stops feeding chunks for that source; there
        // is no rolling buffer here to clear.
        logger.info("clearSource no-op source=\(source.rawValue, privacy: .public)")
    }

    public nonisolated func transcribe(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            Task {
                await self.run(chunks: chunks, output: continuation)
            }
        }
    }

    private func run(
        chunks: AsyncStream<AudioChunk>,
        output: AsyncStream<TranscriptSegment>.Continuation
    ) async {
        let micStream = Self.makeAnalyzerInputStream()
        let systemStream = Self.makeAnalyzerInputStream()
        let micTask = Task {
            await runSource(
                .microphone,
                inputSequence: micStream.stream,
                output: output
            )
        }
        let systemTask = Task {
            await runSource(
                .system,
                inputSequence: systemStream.stream,
                output: output
            )
        }

        var timingBySource: [AudioSource: SourceTiming] = [:]

        for await chunk in chunks {
            do {
                let input = try Self.makeAnalyzerInput(
                    from: chunk,
                    timing: &timingBySource[chunk.source],
                    audioFormat: audioFormat
                )
                switch chunk.source {
                case .microphone:
                    micStream.continuation.yield(input)
                case .system:
                    systemStream.continuation.yield(input)
                }
            } catch {
                logger.error("Failed to convert chunk for SpeechAnalyzer: \(error.localizedDescription, privacy: .public)")
            }
        }

        micStream.continuation.finish()
        systemStream.continuation.finish()
        await micTask.value
        await systemTask.value
        output.finish()
    }

    private func runSource(
        _ source: AudioSource,
        inputSequence: AsyncStream<AnalyzerInput>,
        output: AsyncStream<TranscriptSegment>.Continuation
    ) async {
        do {
            let transcriber = try await makeTranscriber()
            try await prepareAssets(for: transcriber)
            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: .init(priority: .userInitiated, modelRetention: .whileInUse)
            )
            try await analyzer.prepareToAnalyze(in: audioFormat)

            let baseDate = Date()
            let analysisTask = Task {
                try await analyzer.start(inputSequence: inputSequence)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }

            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let volatileRange = await analyzer.volatileRange
                let isVolatile = volatileRange.map { Self.timeRangesIntersect(result.range, $0) } ?? false
                let startOffset = max(0, CMTimeGetSeconds(result.range.start))
                let duration = max(0.01, CMTimeGetSeconds(result.range.duration))
                let start = baseDate.addingTimeInterval(startOffset)
                let end = start.addingTimeInterval(duration)
                let speaker: String? = {
                    if source == .microphone, config.speakerLabelMicrophone {
                        return L10n.string("speaker.you")
                    }
                    return nil
                }()
                output.yield(TranscriptSegment(
                    source: source,
                    speaker: speaker,
                    text: text,
                    startTime: start,
                    endTime: end,
                    isFinal: !isVolatile,
                    confidence: nil,
                    isConfirmed: !isVolatile
                ))
            }

            try await analysisTask.value
        } catch {
            logger.error("SpeechAnalyzer \(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var localeIdentifier: String {
        switch config.language {
        case "ja": return "ja-JP"
        case "en": return "en-US"
        default: return Locale.current.identifier
        }
    }

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerTranscriptionError.unavailable
        }
        let requested = Locale(identifier: localeIdentifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw SpeechAnalyzerTranscriptionError.unsupportedLocale(requested.identifier)
        }
        return SpeechTranscriber(
            locale: supported,
            preset: .timeIndexedProgressiveTranscription
        )
    }

    private func prepareAssets(for transcriber: SpeechTranscriber) async throws {
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw SpeechAnalyzerTranscriptionError.unsupportedLocale(localeIdentifier)
        @unknown default:
            break
        }
    }

    private static func makeAnalyzerInputStream() -> (
        stream: AsyncStream<AnalyzerInput>,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        var continuation: AsyncStream<AnalyzerInput>.Continuation!
        let stream = AsyncStream<AnalyzerInput> { cont in
            continuation = cont
        }
        return (stream, continuation)
    }

    private static func makeAnalyzerInput(
        from chunk: AudioChunk,
        timing: inout SourceTiming?,
        audioFormat: AVAudioFormat
    ) throws -> AnalyzerInput {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ) else {
            throw SpeechAnalyzerTranscriptionError.cannotBuildAudioBuffer
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        guard let channel = buffer.floatChannelData?.pointee else {
            throw SpeechAnalyzerTranscriptionError.cannotBuildAudioBuffer
        }
        chunk.samples.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else { return }
            channel.update(from: sourceBase, count: source.count)
        }

        if timing == nil {
            timing = SourceTiming(nextSampleOffset: 0)
        }
        let startOffset = timing?.nextSampleOffset ?? 0
        timing?.nextSampleOffset = startOffset + Int64(chunk.samples.count)
        let start = CMTime(value: startOffset, timescale: CMTimeScale(Int32(chunk.sampleRate.rounded())))
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }

    private static func timeRangesIntersect(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        let lhsStart = CMTimeGetSeconds(lhs.start)
        let lhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(lhs))
        let rhsStart = CMTimeGetSeconds(rhs.start)
        let rhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(rhs))
        return lhsStart < rhsEnd && rhsStart < lhsEnd
    }
}
