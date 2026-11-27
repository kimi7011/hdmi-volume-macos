import Foundation

@main
enum VolumeControlTests {
    static func main() throws {
        for steps in [16, 32, 64, 100, 200] {
            for index in 0...steps {
                let level = Float32(index) / Float32(steps)
                let next = Float32(min(steps, index + 1)) / Float32(steps)
                let previous = Float32(max(0, index - 1)) / Float32(steps)
                precondition(VolumeControl.closestLevel(to: level, steps: steps) == level)
                precondition(VolumeControl.nextLevel(from: level, direction: 1, steps: steps) == next)
                precondition(VolumeControl.nextLevel(from: level, direction: -1, steps: steps) == previous)
            }
        }
        precondition(VolumeControl.nextLevel(from: 0.3125, direction: 1, steps: 200) == 0.315)
        precondition(VolumeControl.nextLevel(from: 0.3125, direction: -1, steps: 200) == 0.31)
        precondition(VolumeControl.closestLevel(to: 0.353, steps: 200) == 0.355)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("volume-state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AudioVolumeState(volume: 0.3125, muted: true)
        try state.save(to: file)
        precondition(AudioVolumeState.load(from: file) == state)
        precondition(state.gain == 0)
        try Data(#"{"volume":0.125,"muted":false}"#.utf8).write(to: file)
        precondition(AudioVolumeState.load(from: file) == AudioVolumeState(volume: 0.125, muted: false))
        try Data(#"{"volume":1.5,"muted":false}"#.utf8).write(to: file)
        precondition(AudioVolumeState.load(from: file) == nil)
        print("Fine volume steps and legacy volume-state compatibility passed.")
    }
}
