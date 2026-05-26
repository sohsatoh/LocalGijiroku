import Foundation
import AudioToolbox
import AVFoundation
import OSLog

@available(macOS 14.4, *)
final class SystemAudioTap {
    typealias Sink = (AVAudioPCMBuffer, AudioTimeStamp) -> Void

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "SystemAudioTap")
    private let queue = DispatchQueue(label: "SystemAudioTap.io", qos: .userInteractive)

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var sink: Sink?

    func start(sink: @escaping Sink) throws {
        guard tapID == AudioObjectID(kAudioObjectUnknown) else { return }
        self.sink = sink

        // Strategy: pass the *entire* process object list to a mixdown tap.
        // Using `stereoGlobalTapButExcludeProcesses: []` or only currently
        // running-output processes both failed to deliver IO callbacks beyond
        // the first frame on macOS 26 Tahoe in our testing.
        let allProcesses = (try? AudioObjectID.processObjectList()) ?? []
        logger.info("Process tap: handing \(allProcesses.count, privacy: .public) processes to mixdown")

        let description = CATapDescription(stereoMixdownOfProcesses: allProcesses)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        logger.info("CATapDescription uuid=\(description.uuid.uuidString, privacy: .public)")

        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        logger.info("AudioHardwareCreateProcessTap status=\(tapStatus, privacy: .public) tapID=\(newTapID, privacy: .public)")
        guard tapStatus == noErr else {
            throw CoreAudioError.osStatus("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTapID

        let outputID = try AudioObjectID.defaultSystemOutputDevice()
        let outputUID = try outputID.deviceUID()
        let aggregateUID = UUID().uuidString
        logger.info("Default output: deviceID=\(outputID, privacy: .public) uid=\(outputUID, privacy: .public)")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GijirokuTaker-System",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var asbd = try tapID.tapStreamFormat()
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.missing("AVAudioFormat for tap")
        }
        tapFormat = format
        logger.info("Tap format: sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        var newAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        logger.info("AudioHardwareCreateAggregateDevice status=\(aggStatus, privacy: .public) id=\(newAggregateID, privacy: .public)")
        guard aggStatus == noErr else {
            throw CoreAudioError.osStatus("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateDeviceID = newAggregateID

        var procID: AudioDeviceIOProcID?
        var ioCallCount = 0
        var lastLogTime = Date.distantPast
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            queue
        ) { [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.tapFormat else { return }
            ioCallCount += 1
            if ioCallCount == 1 {
                self.logger.info("System tap IO: FIRST CALLBACK frames=\(inputData.pointee.mBuffers.mDataByteSize / 4 / format.channelCount, privacy: .public)")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            let now = Date()
            if now.timeIntervalSince(lastLogTime) >= 5 {
                lastLogTime = now
                let frames = buffer.frameLength
                self.logger.info("System tap IO: calls=\(ioCallCount, privacy: .public) lastFrames=\(frames, privacy: .public)")
            }
            let timestamp = AudioTimeStamp()
            self.sink?(buffer, timestamp)
        }
        logger.info("AudioDeviceCreateIOProcIDWithBlock status=\(createStatus, privacy: .public)")
        guard createStatus == noErr, let procID else {
            throw CoreAudioError.osStatus("AudioDeviceCreateIOProcIDWithBlock", createStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        logger.info("AudioDeviceStart status=\(startStatus, privacy: .public)")
        guard startStatus == noErr else {
            throw CoreAudioError.osStatus("AudioDeviceStart", startStatus)
        }
        logger.info("System tap fully started, waiting for IO callbacks...")
    }

    func stop() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        sink = nil
        tapFormat = nil
    }

    deinit { stop() }
}
