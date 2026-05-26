import Foundation
import AVFoundation
import OSLog
import GijirokuCore

public actor AudioCaptureEngine {
    private static let logger = Logger(subsystem: "com.gijirokutaker.app", category: "AudioCaptureEngine")
    public struct Config: Sendable {
        public let chunkDuration: TimeInterval
        public let targetSampleRate: Double
        public let captureSystem: Bool
        public let captureMicrophone: Bool
        public let preferredInputDeviceUID: String?

        public init(
            chunkDuration: TimeInterval = 1.0,
            targetSampleRate: Double = 16_000,
            captureSystem: Bool = true,
            captureMicrophone: Bool = true,
            preferredInputDeviceUID: String? = nil
        ) {
            self.chunkDuration = chunkDuration
            self.targetSampleRate = targetSampleRate
            self.captureSystem = captureSystem
            self.captureMicrophone = captureMicrophone
            self.preferredInputDeviceUID = preferredInputDeviceUID
        }
    }

    public enum CaptureError: Error {
        case alreadyRunning
    }

    private let config: Config
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var systemBuilder: AudioChunkBuilder?
    private var micBuilder: AudioChunkBuilder?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var waveformContinuations: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]

    public init(config: Config = .init()) {
        self.config = config
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        guard continuation == nil else { throw CaptureError.alreadyRunning }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation

        // Captured by audio IO callbacks. We weak-ref the engine so we can
        // multicast each chunk to the transcription stream AND any waveform
        // subscribers, without retaining the engine from the audio thread.
        let multicast: @Sendable (AudioChunk) -> Void = { [weak self] chunk in
            continuation.yield(chunk)
            guard let self else { return }
            Task { await self.broadcastToWaveformSubscribers(chunk) }
        }

        // Each capture source is started in isolation; one failing (e.g. system
        // audio without screen-recording permission) must not block the other.
        if config.captureSystem {
            let capture = SystemAudioCapture()
            let builder = AudioChunkBuilder(
                source: .system,
                targetSampleRate: config.targetSampleRate,
                chunkDuration: config.chunkDuration,
                onChunk: multicast
            )
            do {
                try await capture.start { buffer in
                    builder.ingest(buffer)
                }
                systemBuilder = builder
                systemCapture = capture
            } catch {
                Self.logger.error("System audio capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if config.captureMicrophone {
            let mic = MicrophoneCapture()
            let builder = AudioChunkBuilder(
                source: .microphone,
                targetSampleRate: config.targetSampleRate,
                chunkDuration: config.chunkDuration,
                onChunk: multicast
            )
            do {
                try mic.start(preferredDeviceUID: config.preferredInputDeviceUID) { buffer in
                    builder.ingest(buffer)
                }
                micBuilder = builder
                micCapture = mic
            } catch {
                Self.logger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        return stream
    }

    /// Subscribes an additional consumer (e.g. waveform UI) to the same chunk
    /// stream the transcription engine sees. The returned AsyncStream finishes
    /// when `stop()` is called.
    public func subscribeWaveform() -> AsyncStream<AudioChunk> {
        let id = UUID()
        return AsyncStream { continuation in
            self.waveformContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeWaveformSubscriber(id) }
            }
        }
    }

    private func removeWaveformSubscriber(_ id: UUID) {
        waveformContinuations.removeValue(forKey: id)
    }

    private func broadcastToWaveformSubscribers(_ chunk: AudioChunk) {
        for cont in waveformContinuations.values {
            cont.yield(chunk)
        }
    }

    public func stop() {
        systemCapture?.stop()
        systemCapture = nil
        micCapture?.stop()
        micCapture = nil
        systemBuilder = nil
        micBuilder = nil
        continuation?.finish()
        continuation = nil
        for cont in waveformContinuations.values {
            cont.finish()
        }
        waveformContinuations.removeAll()
    }
}
