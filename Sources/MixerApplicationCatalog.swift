import AppKit

struct MixerRunningApplication {
    let app: HDMIMixerApp
    var processIDs: Set<pid_t>
}

@MainActor
enum MixerApplicationCatalog {
    private static let executablePrefix = "executable:"

    static func running() -> [String: MixerRunningApplication] {
        var result: [String: MixerRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard let name = app.localizedName, app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.bundleIdentifier != "local.hdmivolume.app" else { continue }
            // Some Wine applications publish a regular window without a macOS bundle identifier.
            let identifier = app.bundleIdentifier ?? executablePrefix + (app.executableURL?.lastPathComponent ?? name)
            if result[identifier] != nil {
                result[identifier]?.processIDs.insert(app.processIdentifier)
            } else {
                let item = HDMIMixerApp(bundleID: identifier, displayName: name, bundleURL: app.bundleURL)
                result[identifier] = MixerRunningApplication(app: item, processIDs: [app.processIdentifier])
            }
        }
        return result
    }

    static func savedApp(_ identifier: String) -> HDMIMixerApp {
        if identifier.hasPrefix(executablePrefix) {
            return HDMIMixerApp(bundleID: identifier, displayName: String(identifier.dropFirst(executablePrefix.count)),
                                bundleURL: nil)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? identifier
        return HDMIMixerApp(bundleID: identifier, displayName: name, bundleURL: url)
    }
}
