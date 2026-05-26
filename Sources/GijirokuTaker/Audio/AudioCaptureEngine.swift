import Foundation
import AVFoundation
import GijirokuCore

@available(macOS 14.4, *)
public actor AudioCaptureEngine {
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
    private var systemTap: SystemAudioTap?
    private var micCapture: MicrophoneCapture?
    private var systemBuilder: AudioChunkBuilder?
    private var micBuilder: AudioChunkBuilder?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    public init(config: Config = .init()) {
        self.config = config
    }

    public func start() throws -> AsyncStream<AudioChunk> {
        guard continuation == nil else { throw CaptureError.alreadyRunning }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation

        if config.captureSystem {
            let tap = SystemAudioTap()
            let builder = AudioChunkBuilder(
                source: .system,
                targetSampleRate: config.targetSampleRate,
                chunkDuration: config.chunkDuration
            ) { chunk in
                continuation.yield(chunk)
            }
            systemBuilder = builder
            try tap.start { buffer, _ in
                builder.ingest(buffer)
            }
            systemTap = tap
        }

        if config.captureMicrophone {
            let mic = MicrophoneCapture()
            let builder = AudioChunkBuilder(
                source: .microphone,
                targetSampleRate: config.targetSampleRate,
                chunkDuration: config.chunkDuration
            ) { chunk in
                continuation.yield(chunk)
            }
            micBuilder = builder
            try mic.start(preferredDeviceUID: config.preferredInputDeviceUID) { buffer in
                builder.ingest(buffer)
            }
            micCapture = mic
        }

        return stream
    }

    public func stop() {
        systemTap?.stop()
        systemTap = nil
        micCapture?.stop()
        micCapture = nil
        systemBuilder = nil
        micBuilder = nil
        continuation?.finish()
        continuation = nil
    }
}
