import Foundation

struct HDMIMixerApp: Equatable {
    let bundleID: String
    let displayName: String
    let bundleURL: URL?
}

struct HDMIMixerRowState: Equatable {
    let app: HDMIMixerApp
    let currentLevel: HDMIMixerLevel?
    let defaultLevel: HDMIMixerLevel
    var isHidden = false
}

struct HDMIMixerLevel: Codable, Equatable {
    var volume: Int
    var muted: Bool

    init(volume: Int = 100, muted: Bool = false) {
        self.volume = min(100, max(0, volume))
        self.muted = muted
    }

    var gain: Float32 { muted ? 0 : Float32(min(100, max(0, volume))) / 100 }
}

struct HDMIMixerSettings: Codable, Equatable {
    private(set) var defaults: [String: HDMIMixerLevel] = [:]
    var hiddenIDs: Set<String> = []

    subscript(bundleID: String) -> HDMIMixerLevel {
        get { defaults[bundleID] ?? HDMIMixerLevel() }
        set {
            let level = HDMIMixerLevel(volume: newValue.volume, muted: newValue.muted)
            defaults[bundleID] = level == HDMIMixerLevel() ? nil : level
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case defaults, hiddenIDs, chrome, music
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hiddenIDs = (try? values.decode(Set<String>.self, forKey: .hiddenIDs)) ?? []
        if let levels = try? values.decode([String: HDMIMixerLevel].self, forKey: .defaults) {
            for (bundleID, level) in levels {
                self[bundleID] = level
            }
        } else {
            self["com.google.Chrome"] = (try? values.decode(HDMIMixerLevel.self, forKey: .chrome)) ?? HDMIMixerLevel()
            self["com.apple.Music"] = (try? values.decode(HDMIMixerLevel.self, forKey: .music)) ?? HDMIMixerLevel()
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(defaults, forKey: .defaults)
        try values.encode(hiddenIDs.sorted(), forKey: .hiddenIDs)
    }
}

enum HDMIMixerPreferences {
    private static var file: URL {
        HDMIPreferences.volumeStateURL.deletingLastPathComponent().appendingPathComponent("app-mixer.json")
    }

    static func load() -> HDMIMixerSettings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(HDMIMixerSettings.self, from: data) else {
            return HDMIMixerSettings()
        }
        return settings
    }

    static func save(_ settings: HDMIMixerSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: file, options: .atomic)
    }
}
