import Foundation
import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import OSLog

// Captures macOS system audio output via ScreenCaptureKit (SCStream). We avoid
// Core Audio Taps because on macOS 26 Tahoe the IO callbacks stop after the
// first frame (Apple Developer Forums #825780, reproduced locally).
//
// SCStream technically requires a `.screen` output to be added even for
// audio-only use. We add one with a very long `minimumFrameInterval` so the
// video pipeline produces almost no work, then ignore those frames.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, @unchecked Sendable {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "SystemAudioCapture")
    private let audioQueue = DispatchQueue(label: "SystemAudioCapture.audio", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "SystemAudioCapture.video", qos: .utility)

    private var stream: SCStream?
    private var sink: Sink?
    private var audioHandler: AudioOutputHandler?
    private var videoHandler: VideoOutputHandler?
    private var callbackCount = 0
    // Set to true by stop() so that didStopWithError does not schedule a restart
    // after an intentional tear-down.
    private var intentionalStop = false

    func start(sink: @escaping Sink) async throws {
        guard stream == nil else { return }
        intentionalStop = false
        self.sink = sink
        logger.info("Requesting SCShareableContent...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No displays available"])
        }
        logger.info("Using display id=\(display.displayID, privacy: .public) \(display.width, privacy: .public)x\(display.height, privacy: .public)")

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Throttle the video pipeline as far as possible: SCStream forces us to
        // attach a .screen output, but we don't actually want frames.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps cap
        config.width = 2
        config.height = 2
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let audioHandler = AudioOutputHandler { [weak self] buffer in
            guard let self else { return }
            self.callbackCount += 1
            if self.callbackCount == 1 {
                self.logger.info("System audio FIRST CALLBACK frames=\(buffer.frameLength, privacy: .public) sr=\(buffer.format.sampleRate, privacy: .public)")
            } else if self.callbackCount.isMultiple(of: 50) {
                self.logger.info("System audio calls=\(self.callbackCount, privacy: .public)")
            }
            self.sink?(buffer)
        }
        self.audioHandler = audioHandler

        let videoHandler = VideoOutputHandler()
        self.videoHandler = videoHandler

        try stream.addStreamOutput(audioHandler, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(videoHandler, type: .screen, sampleHandlerQueue: videoQueue)

        try await stream.startCapture()
        self.stream = stream
        logger.info("SCStream started.")
    }

    func stop() {
        intentionalStop = true
        guard let stream else { return }
        let log = logger
        Task { @Sendable [stream] in
            do {
                try await stream.stopCapture()
            } catch {
                log.error("stopCapture error: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.stream = nil
        self.sink = nil
        self.audioHandler = nil
        self.videoHandler = nil
    }

    deinit { stop() }
}

@available(macOS 13.0, *)
extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
        // If the stream had been delivering audio and was not intentionally stopped
        // (e.g. a phone call activated VoiceProcessingIO and interrupted SCStream),
        // clear state and restart.  We skip restart when callbackCount == 0 because
        // that indicates a persistent failure such as a revoked permission.
        guard !intentionalStop, callbackCount > 0, let savedSink = sink else { return }
        self.stream = nil
        self.audioHandler = nil
        self.videoHandler = nil
        callbackCount = 0
        fputs("[SystemAudioCapture] unexpected stop — scheduling restart in 2 s\n", stderr)
        Task { [weak self] in
            guard let self, !self.intentionalStop else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !self.intentionalStop else { return }
            fputs("[SystemAudioCapture] restarting SCStream\n", stderr)
            try? await self.start(sink: savedSink)
        }
    }
}

@available(macOS 13.0, *)
private final class AudioOutputHandler: NSObject, SCStreamOutput {
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let buffer = sampleBuffer.toAVAudioPCMBuffer() else { return }
        onBuffer(buffer)
    }
}

@available(macOS 13.0, *)
private final class VideoOutputHandler: NSObject, SCStreamOutput {
    // We require this output to exist for SCStream to deliver audio, but we
    // don't need the frames themselves.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // intentional no-op
    }
}

private extension CMSampleBuffer {
    /// Extracts the underlying AudioBufferList and wraps it into a fresh
    /// AVAudioPCMBuffer copy. The block buffer is released with this sample,
    /// so we copy the samples to be safe for downstream async consumers.
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = self.formatDescription else { return nil }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        outBuffer.frameLength = frameCount

        // `AudioBufferList` is a flexible-array-member struct: `mBuffers` is
        // declared as a 1-element array but actually has `mNumberBuffers`
        // entries. For non-interleaved stereo we need 2 `AudioBuffer` slots,
        // so allocating `MemoryLayout<AudioBufferList>.size` is not enough —
        // CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer would
        // happily scribble past the tail and corrupt the malloc heap.
        var blockBuffer: CMBlockBuffer?
        let channelCount = max(1, Int(format.channelCount))
        let ablSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let abPtr = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { abPtr.deallocate() }
        let ablPointer = abPtr.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer,
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
        guard let dstChannelData = outBuffer.floatChannelData else { return nil }

        // SCStream delivers interleaved or planar float depending on configuration;
        // for now we copy by channel assuming planar matches.
        let channels = Int(format.channelCount)
        if abl.count == channels {
            // planar
            for ch in 0..<channels {
                guard let srcPtr = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let bytes = Int(abl[ch].mDataByteSize)
                let count = bytes / MemoryLayout<Float>.size
                let copyCount = min(count, Int(frameCount))
                dstChannelData[ch].update(from: srcPtr, count: copyCount)
            }
        } else if abl.count == 1 {
            // interleaved: deinterleave into planar channels
            guard let srcPtr = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let totalFloats = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let framesAvailable = totalFloats / channels
            let copyCount = min(framesAvailable, Int(frameCount))
            for f in 0..<copyCount {
                for ch in 0..<channels {
                    dstChannelData[ch][f] = srcPtr[f * channels + ch]
                }
            }
        }

        return outBuffer
    }
}
