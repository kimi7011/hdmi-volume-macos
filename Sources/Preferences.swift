import Darwin
import Foundation

struct HDMISettings: Codable, Equatable {
    static let supportedVolumeSteps = [16, 32, 64, 100, 200]

    var launchAtLogin: Bool
    var rememberVolume: Bool
    var volumeSteps: Int
    var keyboardVolumeKeys: Bool

    init(launchAtLogin: Bool = false, rememberVolume: Bool = true, volumeSteps: Int = 100,
         keyboardVolumeKeys: Bool = true) {
        self.launchAtLogin = launchAtLogin
        self.rememberVolume = rememberVolume
        self.keyboardVolumeKeys = keyboardVolumeKeys
        self.volumeSteps = Self.supportedVolumeSteps.contains(volumeSteps) ? volumeSteps : 100
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, rememberVolume, volumeSteps, keyboardVolumeKeys
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            launchAtLogin: (try? values.decode(Bool.self, forKey: .launchAtLogin)) ?? false,
            rememberVolume: (try? values.decode(Bool.self, forKey: .rememberVolume)) ?? true,
            volumeSteps: (try? values.decode(Int.self, forKey: .volumeSteps)) ?? 100,
            keyboardVolumeKeys: (try? values.decode(Bool.self, forKey: .keyboardVolumeKeys)) ?? true
        )
    }
}

enum HDMIPreferences {
    private static let files = FileManager.default
    private static let home = files.homeDirectoryForCurrentUser
    private static let support = home.appendingPathComponent("Library/Application Support/HDMI Volume", isDirectory: true)
    private static let settingsURL = support.appendingPathComponent("settings.json")
    private static let loginLabel = "local.hdmivolume.login"
    private static let loginDirectory = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    private static let loginURL = loginDirectory.appendingPathComponent(loginLabel + ".plist")
    private static let loginDomain = "gui/\(getuid())"
    private static let loginService = "\(loginDomain)/\(loginLabel)"

    static var volumeStateURL: URL { support.appendingPathComponent("volume-state.json") }

    static func load() -> HDMISettings {
        var settings = (try? JSONDecoder().decode(HDMISettings.self, from: Data(contentsOf: settingsURL))) ?? HDMISettings()
        let agent = agentProperties(try? Data(contentsOf: loginURL))
        settings.launchAtLogin = agent?["Label"] as? String == loginLabel
            && agent?["RunAtLoad"] as? Bool == true && !loginIsDisabled()
        return settings
    }

    static func save(_ settings: HDMISettings) throws {
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        let valid = HDMISettings(launchAtLogin: settings.launchAtLogin, rememberVolume: settings.rememberVolume,
                                 volumeSteps: settings.volumeSteps, keyboardVolumeKeys: settings.keyboardVolumeKeys)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(valid).write(to: settingsURL, options: .atomic)
    }

    static func loginNeedsMigration(launcher: URL) -> Bool {
        let agent = agentProperties(try? Data(contentsOf: loginURL))
        let legacy = support.appendingPathComponent("activate-at-login.sh").path
        guard launcher.isFileURL, launcher.standardizedFileURL.path != legacy else { return false }
        return agent?["Label"] as? String == loginLabel && agent?["RunAtLoad"] as? Bool == true
            && agent?["ProgramArguments"] as? [String] == ["/bin/bash", legacy]
    }

    static func setLoginEnabled(_ enabled: Bool, launcher: URL) throws {
        let previous = files.fileExists(atPath: loginURL.path) ? try Data(contentsOf: loginURL) : nil
        let wasLoaded = try launchctl(["print", loginService]).status == 0
        if !enabled {
            if wasLoaded { try runLaunchctl(["bootout", loginService]) }
            do {
                if previous != nil { try files.removeItem(at: loginURL) }
            } catch {
                if wasLoaded, previous != nil { try? runLaunchctl(["bootstrap", loginDomain, loginURL.path]) }
                throw error
            }
            return
        }

        guard launcher.isFileURL, files.isReadableFile(atPath: launcher.path) else {
            throw LoginError(message: "找不到登入啟動程式。請確認 HDMI 音量控制已完整安裝。")
        }
        let arguments = ["/bin/bash", launcher.standardizedFileURL.path]
        let wasDisabled = loginIsDisabled()
        let priorAgent = agentProperties(previous)
        if wasLoaded, !wasDisabled, priorAgent?["Label"] as? String == loginLabel,
           priorAgent?["ProgramArguments"] as? [String] == arguments,
           priorAgent?["RunAtLoad"] as? Bool == true {
            return
        }
        let properties: [String: Any] = [
            "Label": loginLabel,
            "AssociatedBundleIdentifiers": ["local.hdmivolume.app"],
            "LimitLoadToSessionType": "Aqua",
            "ProgramArguments": arguments,
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        if wasLoaded { try runLaunchctl(["bootout", loginService]) }
        do {
            try files.createDirectory(at: loginDirectory, withIntermediateDirectories: true)
            try data.write(to: loginURL, options: .atomic)
            if wasDisabled { try runLaunchctl(["enable", loginService]) }
            try runLaunchctl(["bootstrap", loginDomain, loginURL.path])
        } catch {
            if let previous {
                try? previous.write(to: loginURL, options: .atomic)
                if wasLoaded { try? runLaunchctl(["bootstrap", loginDomain, loginURL.path]) }
            } else if files.fileExists(atPath: loginURL.path) {
                try? files.removeItem(at: loginURL)
            }
            if wasDisabled { try? runLaunchctl(["disable", loginService]) }
            throw error
        }
    }

    private static func agentProperties(_ bytes: Data?) -> [String: Any]? {
        guard let bytes else { return nil }
        return (try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)) as? [String: Any]
    }

    private static func loginIsDisabled() -> Bool {
        guard let result = try? launchctl(["print-disabled", loginDomain]), result.status == 0 else { return false }
        return result.output.split(separator: "\n").contains { line in
            let fields = line.components(separatedBy: "=>")
            guard fields.count == 2 else { return false }
            let service = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let state = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (service == loginLabel || service == "\"\(loginLabel)\"") && state == "disabled"
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let result = try launchctl(arguments)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoginError(message: "無法更新登入啟動設定（launchctl \(result.status)）。\(detail.isEmpty ? "" : "\n" + detail)")
        }
    }

    private static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private struct LoginError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
