import CoreGraphics
import IOKit.hidsystem

@main
struct KeyboardVolumeTests {
    static func main() {
        let up = mediaEvent(NX_KEYTYPE_SOUND_UP)
        let down = mediaEvent(NX_KEYTYPE_SOUND_DOWN)
        precondition(HDMIKeyboardVolume.step(for: up, modifiers: []) == 1)
        precondition(HDMIKeyboardVolume.step(for: down, modifiers: []) == -1)

        precondition(HDMIKeyboardVolume.step(for: mediaEvent(NX_KEYTYPE_SOUND_UP, repeating: true), modifiers: []) == 1)
        precondition(HDMIKeyboardVolume.step(for: mediaEvent(NX_KEYTYPE_SOUND_DOWN, repeating: true), modifiers: []) == -1)
        precondition(HDMIKeyboardVolume.step(for: mediaEvent(NX_KEYTYPE_SOUND_UP, state: NX_KEYUP), modifiers: []) == nil)
        precondition(HDMIKeyboardVolume.step(for: mediaEvent(NX_KEYTYPE_SOUND_DOWN, state: NX_KEYUP), modifiers: []) == nil)
        precondition(HDMIKeyboardVolume.step(for: mediaEvent(NX_KEYTYPE_MUTE), modifiers: []) == nil)
        precondition(HDMIKeyboardVolume.step(for: mediaEvent(NX_KEYTYPE_PLAY), modifiers: []) == nil)

        for modifier: CGEventFlags in [.maskShift, .maskAlternate, .maskControl, .maskCommand] {
            precondition(HDMIKeyboardVolume.step(for: up, modifiers: modifier) == nil)
            precondition(HDMIKeyboardVolume.step(for: down, modifiers: modifier) == nil)
        }
        precondition(HDMIKeyboardVolume.step(for: up, modifiers: [.maskAlternate, .maskShift]) == nil)
        precondition(HDMIKeyboardVolume.step(for: down, modifiers: .maskSecondaryFn) == -1)
        print("Media-volume key decoding, repeats and native pass-through passed.")
    }

    private static func mediaEvent(_ key: Int32, state: Int32 = NX_KEYDOWN, repeating: Bool = false) -> Int {
        Int((UInt32(key) << 16) | (UInt32(state) << 8) | (repeating ? 1 : 0))
    }
}
