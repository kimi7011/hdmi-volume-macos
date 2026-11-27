import AppKit
import ApplicationServices
import IOKit.hidsystem

/// An active event tap owned by the menu application on the main run loop.
final class HDMIKeyboardVolume {
    private let onStep: (Int) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var generation = 0

    init(onStep: @escaping (Int) -> Void) {
        self.onStep = onStep
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return CGEvent.tapIsEnabled(tap: tap)
        }

        // Use the user's session and subscribe only to system-defined events.
        let mask = CGEventMask(1) << UInt32(NX_SYSDEFINED)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hdmiKeyboardVolumeCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let newSource = CFMachPortCreateRunLoopSource(nil, newTap, 0) else { return false }

        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        if CGEvent.tapIsEnabled(tap: newTap) { return true }
        stop()
        return false
    }

    func stop() {
        generation &+= 1
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
    }

    deinit { stop() }

    static func step(for data: Int, modifiers: CGEventFlags) -> Int? {
        let nativeModifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand]
        guard modifiers.intersection(nativeModifiers).isEmpty else { return nil }
        let bits = UInt32(truncatingIfNeeded: data)
        // The state byte is 0x0A for key down, including repeat. Releases are native.
        guard (bits >> 8) & 0xff == 0x0a else { return nil }
        switch Int32(bits >> 16) {
        case NX_KEYTYPE_SOUND_UP: return 1
        case NX_KEYTYPE_SOUND_DOWN: return -1
        default: return nil
        }
    }

    fileprivate func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let activeGeneration = generation
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == activeGeneration, let tap = self.tap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard tap != nil, type.rawValue == UInt32(NX_SYSDEFINED),
              let mediaEvent = NSEvent(cgEvent: event),
              mediaEvent.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
              let direction = Self.step(for: mediaEvent.data1, modifiers: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        // The tap stays responsive while the main app writes the Core Audio property.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == activeGeneration, self.tap != nil else { return }
            self.onStep(direction)
        }
        return nil
    }
}

private let hdmiKeyboardVolumeCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let keyboard = Unmanaged<HDMIKeyboardVolume>.fromOpaque(context).takeUnretainedValue()
    return keyboard.handle(type, event: event)
}
