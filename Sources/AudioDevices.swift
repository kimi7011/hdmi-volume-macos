import AudioToolbox
import CoreAudio
import Foundation

let virtualUID = "HDMIVolumeDevice"

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let media = kAudioHardwarePropertyDefaultOutputDevice
    static let alerts = kAudioHardwarePropertyDefaultSystemOutputDevice
    static let output = kAudioObjectPropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var property = property
        var value = initial
        var bytes = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, $0.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &value)
        return status == noErr ? value.map { $0.takeRetainedValue() as String } : nil
    }

    static func id(for uid: String) -> AudioDeviceID? {
        let uid = uid as CFString
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var id: AudioDeviceID = 0
        var bytes = UInt32(MemoryLayout.size(ofValue: id))
        let status = withUnsafePointer(to: uid) {
            AudioObjectGetPropertyData(system, &property, UInt32(MemoryLayout<CFString>.size), $0, &bytes, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    static func name(_ id: AudioDeviceID) -> String {
        string(id, selector: kAudioObjectPropertyName) ?? "裝置 \(id)"
    }

    static func uid(_ id: AudioDeviceID) -> String? { string(id, selector: kAudioDevicePropertyDeviceUID) }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        read(system, address(selector), AudioDeviceID(0)) ?? 0
    }

    static func setDefault(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws {
        var property = address(selector)
        var id = id
        try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id),
                  "切換系統音訊輸出")
        guard defaultDevice(selector) == id else { throw AudioFailure(message: "macOS 未接受音訊輸出切換。") }
    }

    static func devices() -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &bytes, $0.baseAddress!)
        }
        return status == noErr ? Array(ids.prefix(Int(bytes) / MemoryLayout<AudioDeviceID>.size)) : []
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        read(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) == 1
    }

    static func canOutput(_ id: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyStreams, scope: output)
        var bytes: UInt32 = 0
        return isAlive(id) && AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr && bytes > 0
    }

    static func sonyHDMI() -> [AudioDeviceID] {
        devices().filter { id in
            read(id, address(kAudioDevicePropertyTransportType), UInt32(0)) == kAudioDeviceTransportTypeHDMI
                && name(id).localizedCaseInsensitiveContains("sony") && canOutput(id)
        }
    }

    static func volumeState(_ id: AudioDeviceID) -> AudioVolumeState? {
        let volumeProperty = address(kAudioDevicePropertyVolumeScalar, scope: output)
        let muteProperty = address(kAudioDevicePropertyMute, scope: output)
        guard let scalar = read(id, volumeProperty, Float32(0)),
              let muted = read(id, muteProperty, UInt32(0)) else { return nil }
        let state = AudioVolumeState(volume: scalar, muted: muted != 0)
        return state.isValid ? state : nil
    }

    static func gain(_ id: AudioDeviceID) -> Float? {
        volumeState(id)?.gain
    }

    static func setVolumeState(_ state: AudioVolumeState, on id: AudioDeviceID) throws {
        guard state.isValid else { throw AudioFailure(message: "音量必須介於 0% 到 100%。") }
        let volumeProperty = address(kAudioDevicePropertyVolumeScalar, scope: output)
        let muteProperty = address(kAudioDevicePropertyMute, scope: output)
        // Mute before writing a saved muted level, and unmute only after the level is set.
        if state.muted { try write(id, muteProperty, UInt32(1)) }
        try write(id, volumeProperty, state.volume)
        if !state.muted { try write(id, muteProperty, UInt32(0)) }
    }

    private static func write<T>(_ id: AudioDeviceID, _ property: AudioObjectPropertyAddress, _ value: T) throws {
        var property = property
        let status = withUnsafeBytes(of: value) {
            AudioObjectSetPropertyData(id, &property, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
        try check(status, "調整 HDMI 音量")
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure(message: "\(operation)失敗（Core Audio \(status)）。") }
    }

    static func restore(selector: AudioObjectPropertySelector, previous: String?, target: String?) {
        // Respect an output explicitly selected while the bridge was running.
        guard let virtual = id(for: virtualUID), defaultDevice(selector) == virtual else { return }
        let candidates = [previous, target].compactMap { $0 }.compactMap { id(for: $0) }
        let builtIn = id(for: "BuiltInSpeakerDevice")
        for candidate in candidates + [builtIn].compactMap({ $0 }) + devices() {
            if candidate != virtual, canOutput(candidate), (try? setDefault(candidate, selector: selector)) != nil { return }
        }
    }
}

struct Originals {
    let media: String?
    let alerts: String?
    let target: String

    init(target: String) {
        media = AudioDevices.uid(AudioDevices.defaultDevice(AudioDevices.media))
        alerts = AudioDevices.uid(AudioDevices.defaultDevice(AudioDevices.alerts))
        self.target = target
    }

    init(media: String?, alerts: String?, target: String) {
        self.media = media
        self.alerts = alerts
        self.target = target
    }

    func restore() {
        AudioDevices.restore(selector: AudioDevices.media, previous: media, target: target)
        AudioDevices.restore(selector: AudioDevices.alerts, previous: alerts, target: target)
    }
}
