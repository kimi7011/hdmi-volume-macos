import AudioToolbox
import CoreAudio
import Foundation

private let captureIO: AudioDeviceIOProc = { _, _, input, _, _, _, context in
    guard let context else { return noErr }
    let ring = OpaquePointer(context)
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = buffers.first, let data = first.mData else { return noErr }
    let left = data.assumingMemoryBound(to: Float.self)
    if first.mNumberChannels == 2 {
        let frames = first.mDataByteSize / UInt32(2 * MemoryLayout<Float>.stride)
        _ = HDMIRingWriteInterleaved(ring, left, frames, 2)
    } else if first.mNumberChannels == 1 {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.stride)
        if buffers.count == 2, let right = buffers[1].mData {
            let frames = min(first.mDataByteSize, buffers[1].mDataByteSize) / bytesPerFrame
            _ = HDMIRingWritePlanar(ring, left, right.assumingMemoryBound(to: Float.self), frames)
        } else if buffers.count == 1 {
            _ = HDMIRingWritePlanar(ring, left, nil, first.mDataByteSize / bytesPerFrame)
        }
    }
    return noErr
}

private final class MixerCapture {
    let ring: OpaquePointer
    let layout: HDMIMixerCaptureLayout
    let mixer: OpaquePointer
    let inputs: UnsafeMutablePointer<HDMIRingMixerInput>
    let count: UInt32

    init(ring: OpaquePointer, rate: Double, layout: HDMIMixerCaptureLayout) throws {
        let count = UInt32(layout.buses.count - 1)
        guard let mixer = HDMIAppMixerCreate(rate, count) else {
            throw AudioFailure(message: "無法建立個別 App 混音緩衝區。")
        }
        self.ring = ring
        self.layout = layout
        self.mixer = mixer
        self.inputs = .allocate(capacity: Int(count))
        self.inputs.initialize(repeating: HDMIRingMixerInput(), count: Int(count))
        self.count = count
    }

    deinit {
        inputs.deinitialize(count: Int(count))
        inputs.deallocate()
        HDMIAppMixerDestroy(mixer)
    }
}

private let mixerCaptureIO: AudioDeviceIOProc = { _, _, input, _, _, _, context in
    guard let context else { return noErr }
    let capture = Unmanaged<MixerCapture>.fromOpaque(context).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let layout = capture.layout
    guard buffers.count == layout.bufferCount else { return noErr }
    for index in 0..<Int(capture.count) {
        capture.inputs[index] = layout.buses[index + 1].samples(in: buffers)
    }
    _ = HDMIRingWriteMix(capture.ring, capture.mixer, layout.buses[0].samples(in: buffers),
                       UnsafePointer(capture.inputs), capture.count)
    return noErr
}

private let renderAudio: AURenderCallback = { context, _, _, _, frames, output in
    guard let output else { return kAudio_ParamError }
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    let bytes = Int(frames) * MemoryLayout<Float>.stride
    if buffers.count == 2,
       let left = buffers[0].mData, let right = buffers[1].mData,
       Int(buffers[0].mDataByteSize) >= bytes, Int(buffers[1].mDataByteSize) >= bytes {
        _ = HDMIRingReadPlanar(OpaquePointer(context),
                              left.assumingMemoryBound(to: Float.self),
                              right.assumingMemoryBound(to: Float.self), frames)
    } else {
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
    return noErr
}

/// Short signal sent directly to the virtual device before changing any defaults.
/// The HDMI renderer is at zero gain during this verification.
private final class ProbeSignal {
    let samples: [Float]
    var position = 0

    init(rate: Double) {
        let length = Int(rate * 0.4)
        samples = (0..<length).map { index in
            let envelope = min(1, Double(min(index, length - index)) / (rate * 0.02))
            return Float(0.04 * envelope * sin(2 * Double.pi * 523.25 * Double(index) / rate))
        }
    }
}

private let renderProbe: AURenderCallback = { context, _, _, _, frames, output in
    guard let output else { return kAudio_ParamError }
    let probe = Unmanaged<ProbeSignal>.fromOpaque(context).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    let count = Int(frames)
    probe.samples.withUnsafeBufferPointer { samples in
        for buffer in buffers {
            guard let data = buffer.mData, Int(buffer.mDataByteSize) >= count * MemoryLayout<Float>.stride else { continue }
            let output = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let index = probe.position + i
                output[i] = index < samples.count ? samples[index] : 0
            }
        }
    }
    probe.position = min(probe.samples.count, probe.position + count)
    return noErr
}

private final class OutputUnit {
    private var unit: AudioUnit?
    private var initialized = false

    init(device: AudioDeviceID, rate: Double, callback: AURenderCallback, context: UnsafeMutableRawPointer) throws {
        var type = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &type) else {
            throw AudioFailure(message: "找不到 macOS 的 HAL 輸出元件。")
        }
        var instance: AudioUnit?
        try AudioDevices.check(AudioComponentInstanceNew(component, &instance), "建立音訊輸出")
        guard let instance else { throw AudioFailure(message: "無法建立音訊輸出元件。") }
        unit = instance
        do {
            var selected = device
            try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected)
            var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
            var render = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: context)
            try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render)
            try AudioDevices.check(AudioUnitInitialize(instance), "初始化音訊輸出")
            initialized = true
            try AudioDevices.check(AudioOutputUnitStart(instance), "啟動音訊輸出")
        } catch {
            close()
            throw error
        }
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ bus: AudioUnitElement, _ value: inout T) throws {
        guard let unit else { throw AudioFailure(message: "音訊輸出元件已關閉。") }
        let status = withUnsafeBytes(of: &value) {
            AudioUnitSetProperty(unit, property, scope, bus, $0.baseAddress!, UInt32($0.count))
        }
        try AudioDevices.check(status, "設定音訊輸出 \(property)")
    }

    func close() {
        guard let unit else { return }
        _ = AudioOutputUnitStop(unit)
        if initialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    deinit { close() }
}

private final class CaptureSession {
    let selection: HDMIMixerSelection
    let rate: Double
    let aggregateID: AudioDeviceID
    private let tapIDs: [AudioObjectID]
    private let layout: HDMIMixerCaptureLayout?
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private var mixerCapture: MixerCapture?

    init(selection: HDMIMixerSelection, logStats: Bool) throws {
        var aggregateID = AudioDeviceID(0)
        var tapIDs: [AudioObjectID] = []
        var tapUIDs: [String] = []
        var tapChannels: [UInt32] = []
        var rate: Double = 0
        do {
            for description in HDMIProcessTaps.descriptions(selection: selection) {
                var tapID = AudioObjectID(0)
                try AudioDevices.check(AudioHardwareCreateProcessTap(description, &tapID), "建立系統音訊擷取")
                tapIDs.append(tapID)
                guard let uid = AudioDevices.string(tapID, selector: kAudioTapPropertyUID),
                      let format = AudioDevices.read(tapID, AudioDevices.address(kAudioTapPropertyFormat), AudioStreamBasicDescription()),
                      format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      (1...2).contains(format.mChannelsPerFrame), format.mSampleRate.isFinite, format.mSampleRate >= 8_000,
                      rate == 0 || abs(format.mSampleRate - rate) < 0.5 else {
                    throw AudioFailure(message: "系統音訊擷取沒有提供相容的 PCM 格式。")
                }
                rate = format.mSampleRate
                tapUIDs.append(uid)
                tapChannels.append(format.mChannelsPerFrame)
            }
            let configuration: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "local.hdmivolume.capture." + UUID().uuidString,
                kAudioAggregateDeviceNameKey: "HDMI 音量控制擷取",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: tapUIDs.map { [kAudioSubTapUIDKey: $0] }
            ]
            try AudioDevices.check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID),
                                   "建立私人音訊擷取裝置")
            layout = selection.apps.isEmpty ? nil :
                try HDMIMixerCaptureLayout(aggregateID: aggregateID, tapUIDs: tapUIDs,
                                          tapChannels: tapChannels, logStats: logStats)
        } catch {
            if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
            for tapID in tapIDs { AudioHardwareDestroyProcessTap(tapID) }
            throw error
        }
        self.selection = selection
        self.rate = rate
        self.aggregateID = aggregateID
        self.tapIDs = tapIDs
        if logStats, !selection.apps.isEmpty {
            let clients = selection.apps.map { "\($0.bundleID)=\($0.clients)" }.joined(separator: " ")
            fputs("HDMI mixer clients \(clients)\n", stderr)
        }
    }

    func prepare(ring: OpaquePointer, gains: [String: Float]) throws {
        let callback: AudioDeviceIOProc
        let context: UnsafeMutableRawPointer
        if let layout {
            let capture = try MixerCapture(ring: ring, rate: rate, layout: layout)
            mixerCapture = capture
            for (index, app) in selection.apps.enumerated() {
                HDMIAppMixerSetInitialGain(capture.mixer, UInt32(index), gains[app.bundleID] ?? 1)
            }
            callback = mixerCaptureIO
            context = Unmanaged.passUnretained(capture).toOpaque()
        } else {
            callback = captureIO
            context = UnsafeMutableRawPointer(ring)
        }
        try AudioDevices.check(AudioDeviceCreateIOProcID(aggregateID, callback, context, &ioProc),
                               "建立系統音訊擷取")
        guard ioProc != nil else { throw AudioFailure(message: "無法取得音訊擷取入口。") }
    }

    func start() throws {
        guard let ioProc else { throw AudioFailure(message: "音訊擷取入口尚未準備完成。") }
        try AudioDevices.check(AudioDeviceStart(aggregateID, ioProc), "啟動系統音訊擷取")
        running = true
    }

    func pause() throws {
        guard running, let ioProc else { return }
        try AudioDevices.check(AudioDeviceStop(aggregateID, ioProc), "暫停系統音訊擷取")
        running = false
    }

    func setGains(_ gains: [String: Float]) {
        guard let mixer = mixerCapture?.mixer else { return }
        for (index, app) in selection.apps.enumerated() {
            HDMIAppMixerSetGain(mixer, UInt32(index), gains[app.bundleID] ?? 1)
        }
    }

    func log(gains: [String: Float]) {
        guard let mixer = mixerCapture?.mixer else { return }
        let other = HDMIAppMixerGetRemainderPeak(mixer)
        for (index, app) in selection.apps.enumerated() {
            var stats = HDMIRingAppStats()
            HDMIAppMixerGetStats(mixer, UInt32(index), &stats)
            fputs("HDMI mixer app=\(app.bundleID) gain=\(gains[app.bundleID] ?? 1) input=\(stats.inputPeak) mixed=\(stats.mixedPeak) otherInput=\(other)\n", stderr)
        }
    }

    deinit {
        try? pause()
        if let ioProc { AudioDeviceDestroyIOProcID(aggregateID, ioProc) }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        for tapID in tapIDs { AudioHardwareDestroyProcessTap(tapID) }
    }
}

final class AudioBridge {
    let virtual: AudioDeviceID
    let target: AudioDeviceID
    let originals: Originals

    private var capture: CaptureSession?
    private var ring: OpaquePointer?
    private var sink: OutputUnit?
    private var recovery: Process?
    private var recoveryInput: FileHandle?
    private let logStats = ProcessInfo.processInfo.environment["HDMI_VOLUME_STATS"] != nil
    private let perAppMixer: Bool
    private var appGains: [String: Float] = [:]
    private var appProcessIDs: [String: Set<pid_t>] = [:]
    private var nextMixerUpdate: TimeInterval = 0
    private(set) var isPerAppMixerActive = false
    private(set) var perAppMixerFallbackReason: String?

    init(target: AudioDeviceID, perAppMixer: Bool = false) throws {
        guard let virtual = AudioDevices.id(for: virtualUID), AudioDevices.canOutput(virtual) else {
            throw AudioFailure(message: "系統未載入 HDMI 音量控制驅動程式。")
        }
        guard target != virtual, let uid = AudioDevices.uid(target), AudioDevices.canOutput(target) else {
            throw AudioFailure(message: "電視的音訊輸出目前不可用。")
        }
        self.virtual = virtual
        self.target = target
        self.originals = Originals(target: uid)
        self.perAppMixer = perAppMixer
    }

    func setAppMix(gains: [String: Float], processIDs: [String: Set<pid_t>] = [:]) {
        let next = gains.filter { $0.value.isFinite && $0.value >= 0 && $0.value < 1 }
        let ids = processIDs.filter { next[$0.key] != nil }
        if Set(next.keys) != Set(appGains.keys) || ids != appProcessIDs { nextMixerUpdate = 0 }
        appGains = next
        appProcessIDs = ids
        capture?.setGains(next)
    }

    func start(initialVolume: AudioVolumeState) throws {
        perAppMixerFallbackReason = nil
        if perAppMixer {
            do {
                try start(initialVolume: initialVolume, perApp: true)
                isPerAppMixerActive = true
                if logStats { fputs("HDMI mixer active\n", stderr) }
                return
            } catch {
                perAppMixerFallbackReason = error.localizedDescription
                fputs("HDMI mixer fallback: \(error.localizedDescription)\n", stderr)
            }
        }
        try start(initialVolume: initialVolume, perApp: false)
    }

    private func start(initialVolume: AudioVolumeState, perApp: Bool) throws {
        do {
            let selection = perApp ? HDMIProcessTaps.select(bundleIDs: Set(appGains.keys), processIDs: appProcessIDs) ?? .empty : .empty
            let capture = try CaptureSession(selection: selection, logStats: logStats)
            let captureRate = capture.rate
            guard let outputRate = AudioDevices.read(target, AudioDevices.address(kAudioDevicePropertyNominalSampleRate), Float64(0)),
                  outputRate.isFinite, outputRate >= 8_000,
                  let ring = HDMIRingCreate(captureRate, outputRate) else {
                throw AudioFailure(message: "無法建立 HDMI 音訊緩衝區。")
            }
            self.ring = ring
            HDMIRingSetGain(ring, 0)
            self.capture = capture
            try capture.prepare(ring: ring, gains: appGains)
            try capture.start()
            sink = try OutputUnit(device: target, rate: outputRate, callback: renderAudio, context: UnsafeMutableRawPointer(ring))
            let probeVolume = initialVolume.volume > 0 ? initialVolume.volume : AudioVolumeState.initial.volume
            try AudioDevices.setVolumeState(AudioVolumeState(volume: probeVolume, muted: false), on: virtual)
            let directProbe = try verifySignal(captureRate: captureRate)
            let mediaNow = AudioDevices.uid(AudioDevices.defaultDevice(AudioDevices.media))
            let alertsNow = AudioDevices.uid(AudioDevices.defaultDevice(AudioDevices.alerts))
            guard mediaNow == originals.media, alertsNow == originals.alerts else {
                throw AudioFailure(message: "音訊輸出已經變更。請重新按「開始」。")
            }
            try startRecovery()
            try AudioDevices.setDefault(virtual, selector: AudioDevices.media)
            try AudioDevices.setDefault(virtual, selector: AudioDevices.alerts)
            if !directProbe, try !verifyDefaultSignal() {
                throw AudioFailure(message: "未收到測試音。請在「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」允許此 App 擷取系統音訊，然後再試一次。")
            }
            guard AudioDevices.defaultDevice(AudioDevices.media) == virtual else {
                throw AudioFailure(message: "HDMI 音訊輸出已中斷。")
            }
            try AudioDevices.setVolumeState(initialVolume, on: virtual)
            guard refreshGain() else { throw AudioFailure(message: "HDMI 音訊輸出已中斷。") }
        } catch {
            let previousRecovery = recovery
            stop()
            // Finish an earlier recovery before retrying with the single mixed tap.
            if perApp { previousRecovery?.waitUntilExit() }
            throw error
        }
    }

    private func updateMixer(ring: OpaquePointer) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard isPerAppMixerActive, now >= nextMixerUpdate, let previous = capture else { return true }
        nextMixerUpdate = now + 0.5
        guard let selection = HDMIProcessTaps.select(bundleIDs: Set(appGains.keys), processIDs: appProcessIDs),
              selection != previous.selection else { return true }
        do {
            let replacement = try CaptureSession(selection: selection, logStats: logStats)
            guard abs(replacement.rate - previous.rate) < 0.5 else {
                throw AudioFailure(message: "新音訊軌的取樣率與 HDMI 音訊不同。")
            }
            try replacement.prepare(ring: ring, gains: appGains)
            try previous.pause()
            do {
                // The ring has only one producer. Prepare first, then pause and
                // replace the capture while its HDMI consumer keeps running.
                try replacement.start()
            } catch {
                do { try previous.start() }
                catch {
                    fputs("HDMI mixer could not restore capture: \(error.localizedDescription)\n", stderr)
                    return false
                }
                throw error
            }
            capture = replacement
            if logStats { fputs("HDMI mixer switched to \(selection.apps.count) individual app streams\n", stderr) }
        } catch {
            nextMixerUpdate = now + 3
            fputs("HDMI mixer could not refresh streams: \(error.localizedDescription)\n", stderr)
        }
        return true
    }

    private func verifySignal(captureRate: Double) throws -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let probe = Process()
        probe.executableURL = executable
        probe.arguments = ["--probe", String(captureRate)]
        try probe.run()
        // A separate process makes the signal representative of app playback.
        defer { if probe.isRunning { probe.terminate() } }
        return waitForSignal(seconds: 1.5)
    }

    private func verifyDefaultSignal() throws -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        probe.arguments = ["-v", "0.1", "/System/Library/Sounds/Glass.aiff"]
        try probe.run()
        defer { if probe.isRunning { probe.terminate() } }
        return waitForSignal(seconds: 1.5)
    }

    private func waitForSignal(seconds: TimeInterval) -> Bool {
        guard let ring else { return false }
        let timeout = ProcessInfo.processInfo.systemUptime + seconds
        var stats = HDMIRingStats()
        while ProcessInfo.processInfo.systemUptime < timeout {
            HDMIRingGetStats(ring, &stats)
            if stats.inputPeak > 0.002, stats.renderedFrames > 0 { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if logStats {
            fputs("HDMI probe failed input=\(stats.inputFrames) rendered=\(stats.renderedFrames) inputPeak=\(stats.inputPeak) outputSilence=\(stats.silenceFrames) aggregate=\(capture?.aggregateID ?? 0)\n", stderr)
        }
        return false
    }

    static func emitProbe(rate: Double) throws {
        guard let virtual = AudioDevices.id(for: virtualUID) else { return }
        let probe = ProbeSignal(rate: rate)
        let unit = try OutputUnit(device: virtual, rate: rate, callback: renderProbe,
                                  context: Unmanaged.passUnretained(probe).toOpaque())
        Thread.sleep(forTimeInterval: 0.65)
        withExtendedLifetime(probe) { unit.close() }
    }

    @discardableResult
    func refreshGain() -> Bool {
        guard let ring else { return false }
        guard AudioDevices.uid(target) == originals.target, AudioDevices.canOutput(target),
              AudioDevices.defaultDevice(AudioDevices.media) == virtual,
              let gain = AudioDevices.gain(virtual) else { return false }
        HDMIRingSetGain(ring, gain)
        guard updateMixer(ring: ring) else { return false }
        if logStats {
            var stats = HDMIRingStats()
            HDMIRingGetStats(ring, &stats)
            fputs("HDMI gain=\(gain) inputPeak=\(stats.inputPeak) outputPeak=\(stats.outputPeak) rendered=\(stats.renderedFrames)\n", stderr)
            capture?.log(gains: appGains)
        }
        return true
    }

    private func startRecovery() throws {
        guard let executable = Bundle.main.executableURL else { throw AudioFailure(message: "找不到音訊復原工具。") }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--recover", originals.media ?? "", originals.alerts ?? "", originals.target]
        let input = Pipe()
        let ready = Pipe()
        helper.standardInput = input
        helper.standardOutput = ready
        try helper.run()
        // The single-byte acknowledgement ensures recovery is listening before Core Audio changes.
        let acknowledgement = ready.fileHandleForReading.readData(ofLength: 1)
        guard acknowledgement == Data([1]) else {
            try? input.fileHandleForWriting.close()
            throw AudioFailure(message: "無法啟動音訊復原工具。")
        }
        recovery = helper
        recoveryInput = input.fileHandleForWriting
    }

    func stop() {
        isPerAppMixerActive = false
        if recovery != nil { originals.restore() }
        try? recoveryInput?.close()
        recoveryInput = nil
        recovery = nil
        sink?.close()
        sink = nil
        capture = nil
        if let ring { HDMIRingDestroy(ring); self.ring = nil }
    }

    deinit { stop() }
}
