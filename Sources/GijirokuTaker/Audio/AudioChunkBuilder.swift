import Foundation
import AVFoundation
import OSLog
import GijirokuCore

// Resamples device-native audio (any rate, any channel count) into 16kHz mono
// Float32, then emits fixed-duration AudioChunk values for the given source.
//
// Thread-safe: internal mutation is guarded by `lock`. Marked
// `@unchecked Sendable` so it can be captured by audio-IO closures running on
// background queues from actor-isolated callers.
final class AudioChunkBuilder: @unchecked Sendable {
    private let logger: Logger
    private let source: AudioSource
    private let targetSampleRate: Double
    private let chunkDuration: TimeInterval
    private let onChunk: (AudioChunk) -> Void

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    private var buffer: [Float] = []
    private let lock = NSLock()
    private var ingestCount = 0
    private var emitCount = 0

    init(
        source: AudioSource,
        targetSampleRate: Double = 16_000,
        chunkDuration: TimeInterval = 1.0,
        onChunk: @escaping (AudioChunk) -> Void
    ) {
        self.source = source
        self.targetSampleRate = targetSampleRate
        self.chunkDuration = chunkDuration
        self.onChunk = onChunk
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        self.logger = Logger(subsystem: "com.gijirokutaker.app", category: "AudioChunkBuilder.\(source.rawValue)")
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        ingestCount += 1
        let inFrames = buffer.frameLength
        if ingestCount == 1 {
            logger.info("FIRST ingest format=sr:\(buffer.format.sampleRate, privacy: .public) ch:\(buffer.format.channelCount, privacy: .public) frames=\(inFrames, privacy: .public)")
        } else if ingestCount.isMultiple(of: 50) {
            logger.info("ingest #\(self.ingestCount, privacy: .public) bufferedSamples=\(self.buffer.count, privacy: .public)")
        }

        guard let mono = convertToMono16k(buffer) else {
            if ingestCount <= 5 || ingestCount.isMultiple(of: 50) {
                logger.error("convertToMono16k nil at ingest #\(self.ingestCount, privacy: .public)")
            }
            return
        }
        guard let channelData = mono.floatChannelData?.pointee else {
            logger.error("floatChannelData missing")
            return
        }
        let count = Int(mono.frameLength)
        if ingestCount == 1 {
            logger.info("Resampled frames=\(count, privacy: .public)")
        }
        let slice = UnsafeBufferPointer(start: channelData, count: count)
        self.buffer.append(contentsOf: slice)

        let chunkSize = Int(chunkDuration * targetSampleRate)
        while self.buffer.count >= chunkSize {
            let samples = Array(self.buffer.prefix(chunkSize))
            self.buffer.removeFirst(chunkSize)
            let chunk = AudioChunk(
                source: source,
                samples: samples,
                sampleRate: targetSampleRate,
                startTime: Date()
            )
            emitCount += 1
            if emitCount == 1 || emitCount.isMultiple(of: 10) {
                logger.info("Emit chunk #\(self.emitCount, privacy: .public) samples=\(samples.count, privacy: .public)")
            }
            onChunk(chunk)
        }
    }

    private func convertToMono16k(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFormat = inputBuffer.format
        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: targetFormat)
            converterInputFormat = inFormat
        }
        guard let converter else { return nil }
        // Reset converter state between calls — without this, after the first
        // `.endOfStream` response from the input block the converter stays in a
        // terminal state and subsequent convert calls return zero frames.
        converter.reset()

        let ratio = targetSampleRate / inFormat.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCapacity) else {
            return nil
        }

        var error: NSError?
        var emitted = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if emitted {
                outStatus.pointee = .endOfStream
                return nil
            }
            emitted = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil { return nil }
        if output.frameLength == 0 { return nil }
        return output
    }
}
