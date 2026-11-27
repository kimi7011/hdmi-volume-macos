import Foundation

struct AudioVolumeState: Codable, Equatable {
    var volume: Float32
    var muted: Bool

    static let initial = AudioVolumeState(volume: 0.35, muted: false)

    var isValid: Bool { volume.isFinite && (0...1).contains(volume) }
    var gain: Float32 { muted ? 0 : volume }

    static func load(from file: URL) -> AudioVolumeState? {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(Self.self, from: data),
              state.isValid else { return nil }
        return state
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

enum VolumeControl {
    static func closestLevel(to gain: Float32, steps: Int) -> Float32 {
        let proportion = Double(min(1, max(0, gain)))
        return Float32((proportion * Double(steps)).rounded() / Double(steps))
    }

    static func nextLevel(from gain: Float32, direction: Int, steps: Int) -> Float32 {
        let count = Double(steps)
        let level = Double(min(1, max(0, gain))) * count
        // Float32 storage can place a grid value slightly to either side of its index.
        let nearest = level.rounded()
        let stable = abs(level - nearest) < 0.0001 ? nearest : level
        let next = direction > 0 ? floor(stable) + 1 : ceil(stable) - 1
        return Float32(min(count, max(0, next)) / count)
    }
}
