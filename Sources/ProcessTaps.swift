import AppKit
import CoreAudio
import Darwin
import Foundation

struct HDMIMixerSelection: Equatable {
    struct App: Equatable {
        let bundleID: String
        let clients: [AudioObjectID]
        let matchingBundleIDs: [String]
    }

    let apps: [App]
    static let empty = HDMIMixerSelection(apps: [])
}

enum HDMIProcessTaps {
    static func descriptions(selection: HDMIMixerSelection) -> [CATapDescription] {
        let remainder = CATapDescription(excludingProcesses: selection.apps.flatMap(\.clients),
                                         deviceUID: virtualUID, stream: 0)
        if #available(macOS 26, *) {
            remainder.bundleIDs = selection.apps.flatMap(\.matchingBundleIDs)
        }
        let selected = selection.apps.map { app in
            let description = CATapDescription(processes: app.clients, deviceUID: virtualUID, stream: 0)
            if #available(macOS 26, *) { description.bundleIDs = app.matchingBundleIDs }
            return configure(description, name: app.bundleID)
        }
        return [configure(remainder, name: "HDMI 音量控制")] + selected
    }

    private static func configure(_ description: CATapDescription, name: String) -> CATapDescription {
        description.name = name
        description.muteBehavior = .unmuted
        description.isPrivate = false
        return description
    }

    static func select(bundleIDs: Set<String>, processIDs: [String: Set<pid_t>]) -> HDMIMixerSelection? {
        guard !bundleIDs.isEmpty else { return .empty }
        var property = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        var bytes: UInt32 = 0
        let system = AudioDevices.system
        let stride = MemoryLayout<AudioObjectID>.stride
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &bytes) == noErr else { return nil }
        guard bytes >= stride else { return .empty }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / stride)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &bytes, $0.baseAddress!)
        }
        guard status == noErr else { return nil }

        let running = NSWorkspace.shared.runningApplications
        var guiApps: [pid_t: String] = [:]
        var selectedPaths: [(path: String, bundleID: String)] = []
        for app in running where !app.isTerminated {
            guard let bundleID = app.bundleIdentifier else { continue }
            if app.activationPolicy == .regular || bundleIDs.contains(bundleID) {
                guiApps[app.processIdentifier] = bundleID
            }
            if bundleIDs.contains(bundleID), let path = app.bundleURL?.path {
                selectedPaths.append((path + "/", bundleID))
            }
        }
        for key in processIDs.keys.sorted() where bundleIDs.contains(key) {
            for pid in processIDs[key] ?? [] where pid > 1 {
                guiApps[pid] = key
            }
        }
        selectedPaths.sort { $0.path.count > $1.path.count }

        var groups: [String: [AudioObjectID]] = [:]
        // HAL object IDs identify clients even before the default output is moved.
        // Taps are still scoped to the virtual output stream, so playback to other
        // devices is not intercepted.
        for id in ids.prefix(Int(bytes) / stride) {
            let coreAudioBundle = AudioDevices.string(id, selector: kAudioProcessPropertyBundleID)
            let pid = AudioDevices.read(id, AudioDevices.address(kAudioProcessPropertyPID), pid_t(0)) ?? 0
            if let bundleID = owningApp(pid: pid, reportedBundle: coreAudioBundle, guiApps: guiApps,
                                      selectedPaths: selectedPaths, bundleIDs: bundleIDs) {
                groups[bundleID, default: []].append(id)
            }
        }
        return HDMIMixerSelection(apps: bundleIDs.sorted().compactMap { key in
            let matching = matchingBundleIDs(for: key, selected: bundleIDs)
            let clients = groups[key]?.sorted() ?? []
            guard !matching.isEmpty || !clients.isEmpty else { return nil }
            return HDMIMixerSelection.App(bundleID: key, clients: clients, matchingBundleIDs: matching)
        })
    }

    private static func matchingBundleIDs(for key: String, selected: Set<String>) -> [String] {
        guard #available(macOS 26, *), !key.contains(":") else { return [] }
        let helpers: [String]
        switch key {
        case "com.google.Chrome":
            helpers = ["com.google.Chrome.helper", "com.google.Chrome.helper.renderer"]
        case "com.apple.Music":
            helpers = ["com.apple.Music.VisualizerService"]
        default:
            helpers = []
        }
        return [key] + helpers.filter { !selected.contains($0) }
    }

    private static func owningApp(pid: pid_t, reportedBundle: String?, guiApps: [pid_t: String],
                                  selectedPaths: [(path: String, bundleID: String)], bundleIDs: Set<String>) -> String? {
        if let bundle = guiApps[pid] { return bundleIDs.contains(bundle) ? bundle : nil }
        if let reportedBundle, bundleIDs.contains(reportedBundle) { return reportedBundle }
        guard pid > 1 else { return nil }

        let executable = executablePath(pid)
        if let executable, let app = selectedPaths.first(where: { executable.hasPrefix($0.path) }) {
            return app.bundleID
        }
        var ancestor = pid
        for _ in 0..<16 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid > 1, info.pbi_ppid <= UInt32(Int32.max),
                  pid_t(info.pbi_ppid) != ancestor else { break }
            ancestor = pid_t(info.pbi_ppid)
            if let bundle = guiApps[ancestor] { return bundleIDs.contains(bundle) ? bundle : nil }
        }

        // Chrome and Music workers can be launched by launchd, outside a GUI
        // application's process tree.
        guard let reportedBundle else { return nil }
        if bundleIDs.contains("com.google.Chrome"), reportedBundle.hasPrefix("com.google.Chrome.helper") {
            return "com.google.Chrome"
        }
        if bundleIDs.contains("com.apple.Music"), reportedBundle.hasPrefix("com.apple.Music.") {
            return "com.apple.Music"
        }
        return nil
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let result = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }
}

struct HDMIMixerCaptureLayout {
    struct Bus {
        let buffer: Int
        let channel: Int
        let hasRight: Bool
        let hasSeparateRightBuffer: Bool
        let stride: UInt32

        func samples(in buffers: UnsafeMutableAudioBufferListPointer) -> HDMIRingMixerInput {
            let input = buffers[buffer]
            guard input.mNumberChannels == stride, let inputData = input.mData else { return HDMIRingMixerInput() }
            let bytesPerFrame = stride * UInt32(MemoryLayout<Float>.size)
            let left = inputData.assumingMemoryBound(to: Float.self).advanced(by: channel)
            var frames = input.mDataByteSize / bytesPerFrame
            var right: UnsafePointer<Float>?
            if hasSeparateRightBuffer {
                let separate = buffers[buffer + 1]
                guard separate.mNumberChannels == stride, let rightData = separate.mData else { return HDMIRingMixerInput() }
                frames = min(frames, separate.mDataByteSize / bytesPerFrame)
                right = UnsafePointer(rightData.assumingMemoryBound(to: Float.self))
            } else if hasRight {
                right = UnsafePointer(left.advanced(by: 1))
            }
            return HDMIRingMixerInput(left: UnsafePointer(left), right: right, frames: frames, stride: stride)
        }
    }

    let bufferCount: Int
    let buses: [Bus]

    init(aggregateID: AudioDeviceID, tapUIDs: [String], tapChannels: [UInt32], logStats: Bool) throws {
        let ordered = Self.orderedTapUIDs(aggregateID)
        guard ordered == tapUIDs else {
            throw AudioFailure(message: "macOS 回傳的音訊軌順序與原型設定不符。")
        }
        let channels = try Self.channelCounts(aggregateID)
        if logStats { fputs("HDMI mixer layout taps=\(tapChannels) inputBuffers=\(channels)\n", stderr) }
        guard tapChannels.count >= 2, tapChannels.allSatisfy({ (1...2).contains($0) }),
              channels.allSatisfy({ $0 > 0 }), channels.reduce(0, +) == tapChannels.reduce(0, +) else {
            throw AudioFailure(message: "macOS 回傳的音訊軌聲道數與原型設定不符。")
        }

        var buffer = 0
        var channelInBuffer: UInt32 = 0
        var buses = [Bus]()
        for count in tapChannels {
            let stride = channels[buffer]
            let usesSeparateRight = count == 2 && channelInBuffer + 1 == stride
            if usesSeparateRight, stride != 1 || buffer + 1 >= channels.count || channels[buffer + 1] != 1 {
                throw AudioFailure(message: "macOS 回傳的左右聲道配置不相容。")
            }
            buses.append(Bus(buffer: buffer, channel: Int(channelInBuffer), hasRight: count == 2,
                             hasSeparateRightBuffer: usesSeparateRight, stride: stride))
            channelInBuffer += count
            while buffer < channels.count, channelInBuffer >= channels[buffer] {
                channelInBuffer -= channels[buffer]
                buffer += 1
            }
        }
        bufferCount = channels.count
        self.buses = buses
    }

    private static func orderedTapUIDs(_ device: AudioDeviceID) -> [String]? {
        var address = AudioDevices.address(kAudioAggregateDevicePropertyTapList)
        var value: Unmanaged<CFArray>?
        var bytes = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as? [String]
    }

    private static func channelCounts(_ device: AudioDeviceID) throws -> [UInt32] {
        var address = AudioDevices.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var bytes: UInt32 = 0
        try AudioDevices.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes), "讀取音訊軌配置")
        guard bytes >= MemoryLayout<AudioBufferList>.size else {
            throw AudioFailure(message: "macOS 未提供音訊軌配置。")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try AudioDevices.check(AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, storage), "讀取音訊軌配置")
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.map(\.mNumberChannels)
    }
}
