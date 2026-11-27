import AppKit
import CoreAudio
import Foundation

private let arguments = CommandLine.arguments
if arguments.count == 5 && arguments[1] == "--recover" {
    let route = Originals(media: arguments[2].isEmpty ? nil : arguments[2],
                          alerts: arguments[3].isEmpty ? nil : arguments[3], target: arguments[4])
    try FileHandle.standardOutput.write(contentsOf: Data([1]))
    _ = FileHandle.standardInput.readDataToEndOfFile()
    route.restore()
    exit(0)
}

if arguments.count == 3 && arguments[1] == "--probe",
   let rate = Double(arguments[2]), rate.isFinite, (8_000...384_000).contains(rate) {
    try AudioBridge.emitProbe(rate: rate)
    exit(0)
}

if arguments.count == 2 && arguments[1] == "--recover-login-route" {
    let sony = AudioDevices.sonyHDMI()
    let target = sony.count == 1 ? AudioDevices.uid(sony[0]) : nil
    AudioDevices.restore(selector: AudioDevices.media, previous: nil, target: target)
    AudioDevices.restore(selector: AudioDevices.alerts, previous: nil, target: target)
    exit(0)
}

if arguments.count == 2 && arguments[1] == "--check" {
    let device = AudioDevices.id(for: virtualUID)
    print("virtual: \(device.map(AudioDevices.name) ?? "missing")")
    print("virtual gain: \(device.flatMap(AudioDevices.gain).map { String($0) } ?? "missing")")
    print("media: \(AudioDevices.name(AudioDevices.defaultDevice(AudioDevices.media)))")
    print("alerts: \(AudioDevices.name(AudioDevices.defaultDevice(AudioDevices.alerts)))")
    for sony in AudioDevices.sonyHDMI() { print("Sony HDMI: \(AudioDevices.name(sony))") }
    exit(device == nil ? 1 : 0)
}

@MainActor
final class HDMIApplication: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var bridge: AudioBridge?
    private var timer: Timer?
    private var busy = false
    private var settings = HDMIPreferences.load()
    private var savedVolume = AudioVolumeState.load(from: HDMIPreferences.volumeStateURL)
    private lazy var mixerSettings = HDMIMixerPreferences.load()
    private var runningMixerApps: [String: MixerRunningApplication] = [:]
    private var currentAppLevels: [String: HDMIMixerLevel] = [:]
    private var nextMixerDiscovery: TimeInterval = 0
    private var displayedVolume: Float32?
    private var testMode: Bool { arguments.count == 3 && arguments[1] == "--test-output" }
    private var loginMode: Bool { arguments.dropFirst().first == "--activate-at-login" }
    private var mixerPrototype: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HDMIVolumeMixerPrototype") as? Bool == true
    }
    private var launcher: URL? { Bundle.main.url(forResource: "activate-at-login", withExtension: "sh") }
    private var settingsWindow: HDMISettingsWindowController?
    private var mixerWindow: HDMIAppMixerWindowController?
    private var volumeHUD: HDMIVolumeHUD?
    private var keyboardPermission = false
    private var keyboardTapActive = false
    private var nextKeyboardCheck: TimeInterval = 0
    private lazy var keyboardVolume = HDMIKeyboardVolume(onStep: { [weak self] direction in
        guard let self, self.settings.keyboardVolumeKeys else { return }
        self.stepVolume(direction, showsHUD: true)
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: "HDMI 音量控制")
        updateMenu()
        ProcessInfo.processInfo.disableAutomaticTermination("HDMI audio routing")
        if mixerPrototype {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspace.addObserver(self, selector: #selector(mixerApplicationChanged(_:)), name: name, object: nil)
            }
        }
        if !mixerPrototype, settings.launchAtLogin, let launcher, HDMIPreferences.loginNeedsMigration(launcher: launcher) {
            do { try HDMIPreferences.setLoginEnabled(true, launcher: launcher) }
            catch { fputs("HDMI login migration: \(error.localizedDescription)\n", stderr) }
        }
        if testMode || mixerPrototype || (loginMode && settings.launchAtLogin) { start() }
        if loginMode && arguments.contains("--request-keyboard-access") {
            showSettings()
            requestKeyboardPermission()
        }
    }

    private func updateMenu() {
        let menu = NSMenu()
        if let bridge {
            let connected = menu.addItem(withTitle: "輸出至 " + AudioDevices.name(bridge.target), action: nil, keyEquivalent: "")
            connected.isEnabled = false
        }
        let title = busy ? "正在檢查音訊⋯" : bridge == nil ? "開始控制 Sony HDMI 音量" : "停止並恢復音訊"
        let toggle = menu.addItem(withTitle: title, action: #selector(toggleAudio), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !busy
        if mixerPrototype {
            let mixer = menu.addItem(withTitle: "各 App 音量⋯", action: #selector(showMixer), keyEquivalent: ",")
            mixer.target = self
            let permission = menu.addItem(withTitle: "鍵盤音量鍵授權⋯", action: #selector(requestKeyboardPermission), keyEquivalent: "")
            permission.target = self
        } else {
            let preferences = menu.addItem(withTitle: "設定⋯", action: #selector(showSettings), keyEquivalent: ",")
            preferences.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "結束 HDMI 音量控制", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        item?.menu = menu
        item?.button?.toolTip = bridge == nil ? "HDMI 音量控制" : "HDMI 音量控制使用中"
    }

    @objc private func showSettings() {
        synchronizeKeyboard(force: true)
        if settingsWindow == nil {
            settingsWindow = HDMISettingsWindowController(
                onChange: { [weak self] in self?.changeSettings($0) },
                onVolume: { [weak self] in self?.changeVolume($0) },
                onStep: { [weak self] in self?.stepVolume($0) },
                onKeyboardPermission: { [weak self] in self?.requestKeyboardPermission() }
            )
        }
        settingsWindow?.present(settings: settings, volume: liveVolume()?.gain, keyboardPermission: keyboardPermission)
    }

    @objc private func showMixer() {
        refreshMixerApplications(force: true)
        if mixerWindow == nil {
            mixerWindow = HDMIAppMixerWindowController(
                onCurrentChange: { [weak self] app, level in self?.changeAppVolume(app, level: level) },
                onDefaultChange: { [weak self] app, level in self?.changeAppDefault(app, level: level) },
                onVisibilityChange: { [weak self] app, hidden in self?.changeAppVisibility(app, hidden: hidden) }
            )
        }
        mixerWindow?.present(rows: mixerRows(), enabled: bridge?.isPerAppMixerActive == true)
    }

    private func mixerRows() -> [HDMIMixerRowState] {
        let identifiers = Set(runningMixerApps.keys).union(mixerSettings.defaults.keys).union(mixerSettings.hiddenIDs)
        return identifiers.map { identifier in
            let app = runningMixerApps[identifier]?.app ?? MixerApplicationCatalog.savedApp(identifier)
            return HDMIMixerRowState(app: app, currentLevel: currentAppLevels[identifier],
                                     defaultLevel: mixerSettings[identifier], isHidden: mixerSettings.hiddenIDs.contains(identifier))
        }.sorted {
            if ($0.currentLevel != nil) != ($1.currentLevel != nil) { return $0.currentLevel != nil }
            let byName = $0.app.displayName.localizedStandardCompare($1.app.displayName)
            return byName == .orderedSame ? $0.app.bundleID < $1.app.bundleID : byName == .orderedAscending
        }
    }

    private func refreshMixerWindow() {
        guard let mixerWindow else { return }
        mixerWindow.refresh(rows: mixerRows(), enabled: bridge?.isPerAppMixerActive == true)
    }

    private func refreshMixerApplications(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now >= nextMixerDiscovery else { return }
        nextMixerDiscovery = now + 0.75
        let running = MixerApplicationCatalog.running()
        guard running.mapValues(\.processIDs) != runningMixerApps.mapValues(\.processIDs) else { return }
        for (identifier, app) in running {
            if runningMixerApps[identifier]?.processIDs.isDisjoint(with: app.processIDs) ?? true {
                currentAppLevels[identifier] = mixerSettings[identifier]
            }
        }
        currentAppLevels = currentAppLevels.filter { running[$0.key] != nil }
        runningMixerApps = running
        applyAppMix()
        refreshMixerWindow()
    }

    @objc nonisolated private func mixerApplicationChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshMixerApplications(force: true)
        }
    }

    private func appGains() -> [String: Float] {
        mixerSettings.defaults.mapValues(\.gain).merging(currentAppLevels.mapValues(\.gain)) { _, current in current }
    }

    private func applyAppMix() {
        bridge?.setAppMix(gains: appGains(), processIDs: runningMixerApps.mapValues(\.processIDs))
    }

    private func changeAppVolume(_ identifier: String, level: HDMIMixerLevel) {
        guard bridge?.isPerAppMixerActive == true, let current = currentAppLevels[identifier], current != level else { return }
        currentAppLevels[identifier] = level
        applyAppMix()
        refreshMixerWindow()
    }

    private func changeAppDefault(_ identifier: String, level: HDMIMixerLevel) {
        var next = mixerSettings
        next[identifier] = level
        saveMixerSettings(next)
    }

    private func changeAppVisibility(_ identifier: String, hidden: Bool) {
        var next = mixerSettings
        if hidden { next.hiddenIDs.insert(identifier) } else { next.hiddenIDs.remove(identifier) }
        saveMixerSettings(next)
    }

    private func saveMixerSettings(_ next: HDMIMixerSettings) {
        do {
            try HDMIMixerPreferences.save(next)
            mixerSettings = next
            applyAppMix()
        } catch {
            showAlert("無法儲存混音設定", error.localizedDescription)
        }
        refreshMixerWindow()
    }

    @objc private func toggleAudio() {
        if bridge != nil { stop() } else { start() }
    }

    private func start() {
        guard !busy, bridge == nil else { return }
        if mixerPrototype,
           let virtual = AudioDevices.id(for: virtualUID),
           AudioDevices.defaultDevice(AudioDevices.media) == virtual {
            showStartupError("請先在既有的 HDMI Volume 選單點「停止並恢復音訊」，再啟用各 App 音量原型。")
            return
        }
        let target: AudioDeviceID
        if testMode {
            guard let selected = AudioDevices.id(for: arguments[2]), AudioDevices.canOutput(selected) else {
                showStartupError("找不到指定的測試輸出。")
                return
            }
            target = selected
        } else {
            let devices = AudioDevices.sonyHDMI()
            let current = AudioDevices.defaultDevice(AudioDevices.media)
            if devices.contains(current) {
                target = current
            } else if devices.count == 1, let selected = devices.first {
                target = selected
            } else {
                let message = devices.isEmpty ? "找不到 Sony 電視的 HDMI 音訊。請確認電視已開啟，並切到這台 Mac 的 HDMI 輸入。"
                    : "找到多個 Sony HDMI 音訊裝置。請在「系統設定 → 聲音」選取你要使用的電視，再按一次開始。"
                showStartupError(message)
                return
            }
        }

        let startingVolume = settings.rememberVolume ? savedVolume ?? .initial : .initial
        let useMixer = mixerPrototype
        if useMixer { refreshMixerApplications(force: true) }
        let initialGains = useMixer ? appGains() : [:]
        let initialProcessIDs = runningMixerApps.mapValues(\.processIDs)
        busy = true
        updateMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let route = try AudioBridge(target: target, perAppMixer: useMixer)
                if useMixer {
                    route.setAppMix(gains: initialGains, processIDs: initialProcessIDs)
                }
                try route.start(initialVolume: startingVolume)
                return route
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let route):
                    self.bridge = route
                    let timer = Timer(timeInterval: 0.12, target: self, selector: #selector(self.updateAudio),
                                      userInfo: nil, repeats: true)
                    self.timer = timer
                    RunLoop.main.add(timer, forMode: .common)
                    self.updateAudio()
                    guard self.bridge != nil else { return }
                    if self.testMode || self.loginMode || useMixer { fputs("HDMI route active\n", stderr) }
                    if useMixer {
                        self.applyAppMix()
                        self.showMixer()
                    }
                    if useMixer && arguments.contains("--request-keyboard-access") { self.requestKeyboardPermission() }
                case .failure(let error):
                    self.showStartupError(error.localizedDescription)
                }
                self.updateMenu()
            }
        }
    }

    private func liveVolume() -> AudioVolumeState? {
        guard let bridge, AudioDevices.defaultDevice(AudioDevices.media) == bridge.virtual else { return nil }
        return AudioDevices.volumeState(bridge.virtual)
    }

    private func remember(_ state: AudioVolumeState?) {
        guard settings.rememberVolume, let state, state != savedVolume else { return }
        do {
            try state.save(to: HDMIPreferences.volumeStateURL)
            savedVolume = state
        } catch {
            fputs("HDMI volume memory: \(error.localizedDescription)\n", stderr)
        }
    }

    @objc private func updateAudio() {
        guard bridge?.refreshGain() == true else { stop(); return }
        if mixerPrototype { refreshMixerApplications() }
        synchronizeKeyboard()
        let state = liveVolume()
        remember(state)
        if state?.gain != displayedVolume {
            displayedVolume = state?.gain
            settingsWindow?.refresh(settings: settings, volume: displayedVolume, keyboardPermission: keyboardPermission)
        }
    }

    private func changeVolume(_ requested: Float32) {
        guard requested.isFinite else { return }
        setVolume(VolumeControl.closestLevel(to: requested, steps: settings.volumeSteps))
    }

    private func stepVolume(_ direction: Int, showsHUD: Bool = false) {
        guard let current = liveVolume() else { return }
        let next = VolumeControl.nextLevel(from: current.gain, direction: direction, steps: settings.volumeSteps)
        setVolume(next, showsHUD: showsHUD)
    }

    private func setVolume(_ level: Float32, showsHUD: Bool = false) {
        guard let bridge, AudioDevices.defaultDevice(AudioDevices.media) == bridge.virtual else { return }
        do {
            try AudioDevices.setVolumeState(AudioVolumeState(volume: level, muted: level == 0), on: bridge.virtual)
            updateAudio()
            if showsHUD, let applied = liveVolume()?.gain {
                if volumeHUD == nil { volumeHUD = HDMIVolumeHUD() }
                let anchor = item?.button.flatMap { button in
                    button.window?.convertToScreen(button.convert(button.bounds, to: nil))
                }
                volumeHUD?.show(volume: applied, anchor: anchor)
            }
        } catch {
            settingsWindow?.refresh(settings: settings, volume: liveVolume()?.gain, keyboardPermission: keyboardPermission)
            showAlert("無法調整 HDMI 音量", error.localizedDescription)
        }
    }

    private func changeSettings(_ next: HDMISettings) {
        guard !busy else {
            settingsWindow?.refresh(settings: settings, volume: liveVolume()?.gain, keyboardPermission: keyboardPermission)
            return
        }
        let previous = settings
        do {
            if next.launchAtLogin != previous.launchAtLogin {
                guard let launcher else { throw AudioFailure(message: "找不到登入啟動程式。") }
                try HDMIPreferences.setLoginEnabled(next.launchAtLogin, launcher: launcher)
                do { try HDMIPreferences.save(next) }
                catch {
                    try? HDMIPreferences.setLoginEnabled(previous.launchAtLogin, launcher: launcher)
                    throw error
                }
            } else {
                try HDMIPreferences.save(next)
            }
            settings = next
            synchronizeKeyboard(force: true)
            remember(liveVolume())
        } catch {
            showAlert("無法儲存 HDMI 設定", error.localizedDescription)
        }
        settingsWindow?.refresh(settings: settings, volume: liveVolume()?.gain, keyboardPermission: keyboardPermission)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        synchronizeKeyboard(force: true)
    }

    @objc private func requestKeyboardPermission() {
        HDMIKeyboardVolume.requestPermission()
        synchronizeKeyboard(force: true)
    }

    private func synchronizeKeyboard(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now >= nextKeyboardCheck else { return }
        nextKeyboardCheck = now + 1

        let permission = settings.keyboardVolumeKeys && HDMIKeyboardVolume.hasPermission
        let tapping: Bool
        if permission && bridge != nil {
            tapping = keyboardVolume.start()
        } else {
            keyboardVolume.stop()
            tapping = false
        }
        if tapping && !keyboardTapActive {
            fputs("HDMI keyboard volume keys active\n", stderr)
        }
        keyboardTapActive = tapping
        if !tapping { volumeHUD?.dismiss() }
        if keyboardPermission != permission {
            keyboardPermission = permission
            settingsWindow?.refresh(settings: settings, volume: liveVolume()?.gain, keyboardPermission: permission)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        keyboardVolume.stop()
        volumeHUD?.dismiss()
        keyboardTapActive = false
        remember(liveVolume())
        bridge?.stop()
        bridge = nil
        displayedVolume = nil
        settingsWindow?.refresh(settings: settings, volume: nil, keyboardPermission: keyboardPermission)
        refreshMixerWindow()
        updateMenu()
    }

    private func showStartupError(_ message: String) {
        if testMode || loginMode {
            fputs("HDMI error: \(message)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        showAlert("無法啟動 HDMI 音量控制", message)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if mixerPrototype { NSWorkspace.shared.notificationCenter.removeObserver(self) }
        stop()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = HDMIApplication()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
