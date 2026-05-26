import Foundation
import AudioToolbox
import CoreAudio

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case missing(String)

    var description: String {
        switch self {
        case .osStatus(let op, let code): return "\(op) failed with OSStatus \(code)"
        case .missing(let what): return "Missing \(what)"
        }
    }
}

extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func defaultSystemOutputDevice() throws -> AudioDeviceID {
        try read(
            on: .systemObject,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioDeviceID(kAudioObjectUnknown)
        )
    }

    static func processObjectList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr else { throw CoreAudioError.osStatus("ProcessObjectList size", status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        guard status == noErr else { throw CoreAudioError.osStatus("ProcessObjectList data", status) }
        return ids
    }

    func processIsRunningOutput() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        return status == noErr && value == 1
    }

    func processBundleID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let str = cf as String
        return str.isEmpty ? nil : str
    }

    func deviceUID() throws -> String {
        try AudioObjectID.readString(on: self, selector: kAudioDevicePropertyDeviceUID)
    }

    func tapStreamFormat() throws -> AudioStreamBasicDescription {
        try AudioObjectID.read(
            on: self,
            selector: kAudioTapPropertyFormat,
            defaultValue: AudioStreamBasicDescription()
        )
    }

    static func read<T>(
        on object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize)
        guard status == noErr else { throw CoreAudioError.osStatus("AudioObjectGetPropertyDataSize", status) }

        var value: T = defaultValue
        status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { throw CoreAudioError.osStatus("AudioObjectGetPropertyData", status) }
        return value
    }

    static func readString(
        on object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        let cf: CFString = try read(
            on: object,
            selector: selector,
            scope: scope,
            element: element,
            defaultValue: "" as CFString
        )
        return cf as String
    }
}
