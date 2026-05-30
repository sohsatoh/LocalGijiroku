import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import OSLog

final class MicrophoneCapture {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "MicrophoneCapture")
    private let engine = AVAudioEngine()
    private var sink: Sink?
    private var preferredDeviceUID: String?
    private(set) var isRunning = false
    private var callbackCount = 0
    private var configChangeObserver: NSObjectProtocol?

    var inputFormat: AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    func start(
        preferredDeviceUID: String? = nil,
        sink: @escaping Sink
    ) throws {
        guard !isRunning else { return }
        self.sink = sink
        self.preferredDeviceUID = preferredDeviceUID

        try startEngine(preferredDeviceUID: preferredDeviceUID)
        isRunning = true

        // When a phone call starts the OS may reconfigure the audio hardware
        // (VoiceProcessingIO takes over the input device).  Restart the engine so
        // we keep receiving audio on the new configuration.
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.logger.info("AVAudioEngine configuration changed — restarting mic engine")
                fputs("[MicrophoneCapture] configuration change, restarting\n", stderr)
                self.restartEngineAfterConfigurationChange()
            }
        }
    }

    private func startEngine(preferredDeviceUID: String?) throws {
        if let uid = preferredDeviceUID, !uid.isEmpty {
            if let deviceID = Self.findDeviceID(uid: uid) {
                try setInputDevice(deviceID)
                logger.info("Mic input device set to uid=\(uid, privacy: .public) id=\(deviceID, privacy: .public)")
            } else {
                logger.error("Mic input device with uid=\(uid, privacy: .public) not found; falling back to default")
            }
        }

        let node = engine.inputNode

        // Apple の VoiceProcessingIO は副作用として speaker output を ducking
        // するため、本アプリでは使用しない。スピーカー音がマイクに回り込む
        // 「bleed」問題は TranscriptDeduper のクロスソース dedup で解決する
        // (詳細はそちらのコメント参照)。

        let format = node.inputFormat(forBus: 0)
        logger.info("Mic input format: sampleRate=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
        node.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.callbackCount += 1
            if self.callbackCount == 1 {
                self.logger.info("Mic IO: FIRST CALLBACK frames=\(buffer.frameLength, privacy: .public)")
            } else if self.callbackCount.isMultiple(of: 50) {
                self.logger.info("Mic IO: calls=\(self.callbackCount, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
            }
            self.sink?(buffer)
        }
        try engine.start()
        logger.info("Mic engine started, waiting for callbacks...")
    }

    private func restartEngineAfterConfigurationChange() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        callbackCount = 0

        do {
            try startEngine(preferredDeviceUID: preferredDeviceUID)
        } catch {
            logger.error("Mic engine restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw NSError(domain: "MicrophoneCapture", code: -1)
        }
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        if status != noErr {
            throw NSError(domain: "MicrophoneCapture", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AudioUnitSetProperty failed (\(status))"])
        }
    }

    private static func findDeviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            if let candidate = Self.readUID(id), candidate == uid {
                return id
            }
        }
        return nil
    }

    private static func readUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cf as String
    }

    func stop() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink = nil
        preferredDeviceUID = nil
        isRunning = false
    }
}
