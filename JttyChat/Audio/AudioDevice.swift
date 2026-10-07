import CoreAudio
import Foundation

/// One CoreAudio device available for input or output. Ported from
/// JttyChatLinux's use of QMediaDevices::audioInputs()/audioOutputs(); uid
/// is the stable identifier to persist (device ids can change across
/// reconnects/reboots, the UID string doesn't).
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceLister {
    static func inputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { channelCount(for: $0.id, scope: kAudioDevicePropertyScopeInput) > 0 }
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { channelCount(for: $0.id, scope: kAudioDevicePropertyScopeOutput) > 0 }
    }

    static func defaultInputDevice() -> AudioDeviceInfo? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDevice() -> AudioDeviceInfo? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - CoreAudio plumbing

    private static func allDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                              &dataSize) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize,
                                          &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard let name = deviceName(for: id) else { return nil }
            return AudioDeviceInfo(id: id, uid: deviceUID(for: id) ?? String(id), name: name)
        }
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize,
                                          &deviceID) == noErr, deviceID != 0 else { return nil }
        guard let name = deviceName(for: deviceID) else { return nil }
        return AudioDeviceInfo(id: deviceID, uid: deviceUID(for: deviceID) ?? String(deviceID), name: name)
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                   mScope: scope,
                                                   mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                                                    alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return 0
        }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name) == noErr else { return nil }
        return name as String
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid) == noErr else { return nil }
        return uid as String
    }

    // Resolves a persisted device UID back to a live AudioDeviceID, since
    // ids themselves aren't stable across reconnects/reboots. Falls back to
    // the given default if the saved device can't be found (e.g. it was
    // unplugged), matching JttyChatLinux's SettingsDialog::selectDevice.
    static func resolve(uid: String?, fallback: AudioDeviceInfo?) -> AudioDeviceInfo? {
        if let uid, let match = allDevices().first(where: { $0.uid == uid }) {
            return match
        }
        return fallback
    }
}
