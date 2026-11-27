import AppKit

private final class HDMIVolumeSlider: NSSlider {
    private(set) var isTrackingPointer = false
    var trackingEnded: (() -> Void)?
    var stepByKey: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        isTrackingPointer = true
        defer {
            isTrackingPointer = false
            trackingEnded?()
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isEnabled, let stepByKey, let key = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(key.value) {
            case NSLeftArrowFunctionKey, NSDownArrowFunctionKey:
                stepByKey(-1)
                return
            case NSRightArrowFunctionKey, NSUpArrowFunctionKey:
                stepByKey(1)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

final class HDMISettingsWindowController: NSWindowController {
    private let loginSwitch = NSSwitch()
    private let rememberSwitch = NSSwitch()
    private let keyboardSwitch = NSSwitch()
    private let keyboardPermissionButton = NSButton(title: "允許鍵盤音量鍵", target: nil, action: nil)
    private let stepsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeSlider = HDMIVolumeSlider(frame: .zero)
    private let decreaseButton = NSButton(title: "−", target: nil, action: nil)
    private let increaseButton = NSButton(title: "+", target: nil, action: nil)
    private let volumeValue = NSTextField(labelWithString: "未啟用")
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 4
        return formatter
    }()
    private let onChange: (HDMISettings) -> Void
    private let onVolume: (Float32) -> Void
    private let onStep: (Int) -> Void
    private let onKeyboardPermission: () -> Void
    private var currentSettings: HDMISettings?
    private var currentVolume: Float32?
    private var keyboardPermission = false

    init(onChange: @escaping (HDMISettings) -> Void,
         onVolume: @escaping (Float32) -> Void,
         onStep: @escaping (Int) -> Void,
         onKeyboardPermission: @escaping () -> Void) {
        self.onChange = onChange
        self.onVolume = onVolume
        self.onStep = onStep
        self.onKeyboardPermission = onKeyboardPermission
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 302),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "HDMI 音量控制設定"
        window.isReleasedWhenClosed = false
        window.center()
        configureControls()
        installLayout(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present(settings: HDMISettings, volume: Float32?, keyboardPermission: Bool) {
        refresh(settings: settings, volume: volume, keyboardPermission: keyboardPermission)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func refresh(settings: HDMISettings, volume: Float32?, keyboardPermission: Bool) {
        if currentSettings?.launchAtLogin != settings.launchAtLogin {
            loginSwitch.state = settings.launchAtLogin ? .on : .off
        }
        if currentSettings?.rememberVolume != settings.rememberVolume {
            rememberSwitch.state = settings.rememberVolume ? .on : .off
        }
        if currentSettings?.keyboardVolumeKeys != settings.keyboardVolumeKeys {
            keyboardSwitch.state = settings.keyboardVolumeKeys ? .on : .off
        }
        if currentSettings?.volumeSteps != settings.volumeSteps {
            stepsPopup.selectItem(withTag: settings.volumeSteps)
        }
        currentSettings = settings
        self.keyboardPermission = keyboardPermission
        renderKeyboardPermission()
        let value = volume.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        if currentVolume != value {
            currentVolume = value
            renderVolume()
        }
    }

    private func configureControls() {
        for (toggle, label) in [(loginSwitch, "登入時自動啟用"), (rememberSwitch, "記住上次音量"),
                                (keyboardSwitch, "鍵盤音量鍵細調")] {
            toggle.target = self
            toggle.action = #selector(changePreferences)
            toggle.setAccessibilityLabel(label)
        }
        keyboardPermissionButton.bezelStyle = .rounded
        keyboardPermissionButton.controlSize = .small
        keyboardPermissionButton.toolTip = "在「系統設定」中允許使用鍵盤音量鍵"
        keyboardPermissionButton.target = self
        keyboardPermissionButton.action = #selector(requestKeyboardPermission)
        renderKeyboardPermission()

        for steps in HDMISettings.supportedVolumeSteps {
            let title = "\(steps) 段 · 每次 \(percent(1 / Double(steps)))"
            stepsPopup.addItem(withTitle: title)
            stepsPopup.lastItem?.tag = steps
        }
        stepsPopup.target = self
        stepsPopup.action = #selector(changePreferences)
        stepsPopup.setAccessibilityLabel("細調音量")

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(sliderChanged)
        volumeSlider.setAccessibilityLabel("HDMI 輸出音量")
        volumeSlider.trackingEnded = { [weak self] in self?.renderVolume() }
        volumeSlider.stepByKey = { [weak self] direction in self?.onStep(direction) }

        for (button, symbol, label, direction) in [(decreaseButton, "speaker.minus", "降低音量一段", -1),
                                                   (increaseButton, "speaker.plus", "提高音量一段", 1)] {
            button.bezelStyle = .rounded
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                button.image = image
                button.imagePosition = .imageOnly
            }
            button.target = self
            button.action = #selector(stepVolume)
            button.tag = direction
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        volumeValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        volumeValue.alignment = .right
        volumeValue.setAccessibilityLabel("目前輸出音量")
        volumeValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        renderVolume()
    }

    private func installLayout(in window: NSWindow) {
        let volumeLabel = NSTextField(labelWithString: "輸出音量")
        volumeLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let volumeHeader = alignedRow(label: volumeLabel, control: volumeValue)
        let volumeRow = NSStackView(views: [decreaseButton, volumeSlider, increaseButton])
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        volumeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        volumeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let volumeGroup = group(rows: [volumeHeader, volumeRow], spacing: 8, verticalInset: 12)

        let keyboardActions = NSStackView(views: [keyboardPermissionButton, keyboardSwitch])
        keyboardActions.alignment = .centerY
        keyboardActions.spacing = 9
        keyboardActions.detachesHiddenViews = true
        let preferences = [settingRow("登入時自動啟用", control: loginSwitch),
                           settingRow("記住上次音量", control: rememberSwitch),
                           settingRow("鍵盤音量鍵細調", control: keyboardActions),
                           settingRow("細調音量", control: stepsPopup)]
        var preferenceRows: [NSView] = []
        for row in preferences {
            if !preferenceRows.isEmpty {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                preferenceRows.append(separator)
            }
            preferenceRows.append(row)
        }
        let preferencesGroup = group(rows: preferenceRows, spacing: 0, verticalInset: 4)

        let stack = NSStackView(views: [volumeGroup, preferencesGroup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            volumeGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preferencesGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func settingRow(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.setAccessibilityElement(false)
        let row = alignedRow(label: label, control: control)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    private func alignedRow(label: NSTextField, control: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func group(rows: [NSView], spacing: CGFloat, verticalInset: CGFloat) -> NSView {
        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let rowsStack = NSStackView(views: rows)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = spacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            rowsStack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            rowsStack.topAnchor.constraint(equalTo: background.topAnchor, constant: verticalInset),
            rowsStack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -verticalInset),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: rowsStack.widthAnchor) })
        return background
    }

    private func percent(_ fraction: Double) -> String {
        percentFormatter.string(from: NSNumber(value: fraction)) ?? "\(fraction * 100)%"
    }

    private func renderVolume() {
        let enabled = currentVolume != nil
        volumeSlider.isEnabled = enabled
        decreaseButton.isEnabled = enabled
        increaseButton.isEnabled = enabled
        volumeValue.textColor = enabled ? .labelColor : .secondaryLabelColor
        volumeValue.stringValue = currentVolume.map { percent(Double($0)) } ?? "未啟用"
        volumeSlider.toolTip = enabled ? nil : "啟用 HDMI 音量控制後可調整"
        if !volumeSlider.isTrackingPointer {
            volumeSlider.floatValue = currentVolume ?? 0
        }
    }

    private func renderKeyboardPermission() {
        let hidden = currentSettings?.keyboardVolumeKeys != true || keyboardPermission
        if keyboardPermissionButton.isHidden != hidden {
            keyboardPermissionButton.isHidden = hidden
        }
    }

    @objc private func changePreferences() {
        guard var settings = currentSettings, let steps = stepsPopup.selectedItem?.tag else { return }
        settings.launchAtLogin = loginSwitch.state == .on
        settings.rememberVolume = rememberSwitch.state == .on
        settings.keyboardVolumeKeys = keyboardSwitch.state == .on
        settings.volumeSteps = steps
        currentSettings = settings
        renderKeyboardPermission()
        onChange(settings)
    }

    @objc private func requestKeyboardPermission() { onKeyboardPermission() }

    @objc private func sliderChanged() {
        guard currentVolume != nil else { return }
        onVolume(volumeSlider.floatValue)
    }

    @objc private func stepVolume(_ button: NSButton) {
        guard currentVolume != nil else { return }
        onStep(button.tag)
    }
}
