import Foundation

public enum AudioSource: String, Codable, Sendable {
    case microphone
    case system
}

public struct AudioChunk: Sendable {
    public let source: AudioSource
    public let samples: [Float]
    public let sampleRate: Double
    public let startTime: Date

    public init(source: AudioSource, samples: [Float], sampleRate: Double, startTime: Date) {
        self.source = source
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}
