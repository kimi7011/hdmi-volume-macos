import AppKit

@MainActor
final class HDMIAppMixerWindowController: NSWindowController {
    private let list = NSStackView()
    private let hiddenButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hint = NSTextField(labelWithString: "")
    private let onCurrentChange: (String, HDMIMixerLevel) -> Void
    private let onDefaultChange: (String, HDMIMixerLevel) -> Void
    private let onVisibilityChange: (String, Bool) -> Void
    private var appViews: [String: AppMixerRow] = [:]
    private var displayedIDs: [String]?
    private var hiddenApps: [HDMIMixerApp]?
    private var listWidths: [NSLayoutConstraint] = []

    init(onCurrentChange: @escaping (String, HDMIMixerLevel) -> Void,
         onDefaultChange: @escaping (String, HDMIMixerLevel) -> Void,
         onVisibilityChange: @escaping (String, Bool) -> Void) {
        self.onCurrentChange = onCurrentChange
        self.onDefaultChange = onDefaultChange
        self.onVisibilityChange = onVisibilityChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 468),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "個別 App 音量"
        window.contentMinSize = NSSize(width: 430, height: 272)
        window.isReleasedWhenClosed = false
        window.center()
        installLayout(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present(rows: [HDMIMixerRowState], enabled: Bool) {
        refresh(rows: rows, enabled: enabled)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func refresh(rows: [HDMIMixerRowState], enabled: Bool) {
        let visible = rows.filter { !$0.isHidden }
        let ids = visible.map(\.app.bundleID)
        if displayedIDs != ids {
            rebuildList(visible)
            displayedIDs = ids
        }
        for state in visible {
            appViews[state.app.bundleID]?.refresh(state, currentEnabled: enabled)
        }
        let hidden = rows.filter(\.isHidden).map(\.app)
        if hiddenApps != hidden {
            rebuildHiddenMenu(hidden)
            hiddenApps = hidden
        }
        let message = enabled
            ? "控制中心與鍵盤調整總音量。預設值會在 App 下次開啟時套用。"
            : "啟用 Sony HDMI 控制後，即可調整 App 的目前音量。"
        if hint.stringValue != message {
            hint.stringValue = message
        }
    }

    private func rebuildList(_ rows: [HDMIMixerRowState]) {
        NSLayoutConstraint.deactivate(listWidths)
        for subview in list.arrangedSubviews {
            list.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        let previous = appViews
        appViews.removeAll(keepingCapacity: true)
        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "目前沒有顯示的 App")
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
        }
        for state in rows {
            if !list.arrangedSubviews.isEmpty {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                list.addArrangedSubview(separator)
            }
            let id = state.app.bundleID
            let row = previous[id] ?? AppMixerRow(
                onCurrentChange: { [weak self] level in self?.onCurrentChange(id, level) },
                onDefaultChange: { [weak self] level in self?.onDefaultChange(id, level) },
                onHide: { [weak self] in self?.onVisibilityChange(id, true) }
            )
            appViews[id] = row
            list.addArrangedSubview(row)
        }
        listWidths = list.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: list.widthAnchor) }
        NSLayoutConstraint.activate(listWidths)
    }

    private func rebuildHiddenMenu(_ apps: [HDMIMixerApp]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "已隱藏的 App", action: nil, keyEquivalent: ""))
        if apps.isEmpty {
            let empty = NSMenuItem(title: "沒有已隱藏的 App", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for app in apps {
            let item = NSMenuItem(title: "顯示「\(app.displayName)」", action: #selector(unhideApp), keyEquivalent: "")
            item.representedObject = app.bundleID
            item.target = self
            menu.addItem(item)
        }
        hiddenButton.menu = menu
    }

    @objc private func unhideApp(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onVisibilityChange(id, false)
    }

    private func installLayout(in window: NSWindow) {
        let document = AppMixerDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let group = NSVisualEffectView()
        group.material = .contentBackground
        group.blendingMode = .withinWindow
        group.state = .followsWindowActiveState
        group.wantsLayer = true
        group.layer?.cornerRadius = 12
        group.layer?.masksToBounds = true
        group.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(scroll)

        hiddenButton.bezelStyle = .rounded
        hiddenButton.setAccessibilityLabel("已隱藏的 App")
        hiddenButton.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(hiddenButton)
        content.addSubview(group)
        content.addSubview(hint)
        window.contentView = content
        NSLayoutConstraint.activate([
            hiddenButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hiddenButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            group.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            group.trailingAnchor.constraint(equalTo: hiddenButton.trailingAnchor),
            group.topAnchor.constraint(equalTo: hiddenButton.bottomAnchor, constant: 9),
            hint.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            hint.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 11),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: group.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: group.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
        ])
    }
}

private final class AppMixerDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class AppMixerRow: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let hideButton = NSButton(title: "隱藏", target: nil, action: nil)
    private let current: AppMixerControls
    private let launchDefault: AppMixerControls
    private let onHide: () -> Void
    private var app: HDMIMixerApp?

    init(onCurrentChange: @escaping (HDMIMixerLevel) -> Void,
         onDefaultChange: @escaping (HDMIMixerLevel) -> Void,
         onHide: @escaping () -> Void) {
        current = AppMixerControls(title: "目前音量", onChange: onCurrentChange)
        launchDefault = AppMixerControls(title: "開啟時預設", onChange: onDefaultChange)
        self.onHide = onHide
        super.init(frame: .zero)

        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hideButton.controlSize = .small
        hideButton.bezelStyle = .rounded
        hideButton.target = self
        hideButton.action = #selector(hideApp)
        let header = NSStackView(views: [icon, name, hideButton])
        header.alignment = .centerY
        header.spacing = 7

        let stack = NSStackView(views: [header, current, launchDefault])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 23),
            icon.heightAnchor.constraint(equalToConstant: 23),
            hideButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            current.widthAnchor.constraint(equalTo: stack.widthAnchor),
            launchDefault.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func refresh(_ state: HDMIMixerRowState, currentEnabled: Bool) {
        if state.app != app {
            app = state.app
            name.stringValue = state.app.displayName
            if let url = state.app.bundleURL {
                icon.image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                icon.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
                icon.contentTintColor = .secondaryLabelColor
            }
            hideButton.setAccessibilityLabel("隱藏 \(state.app.displayName)")
            current.setAppName(state.app.displayName)
            launchDefault.setAppName(state.app.displayName)
        }
        current.refresh(state.currentLevel, enabled: currentEnabled)
        launchDefault.refresh(state.defaultLevel, enabled: true)
    }

    @objc private func hideApp() {
        onHide()
    }
}

@MainActor
private final class AppMixerControls: NSView {
    private let title: String
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton(title: "靜音", target: nil, action: nil)
    private let onChange: (HDMIMixerLevel) -> Void
    private var appName = ""
    private var level: HDMIMixerLevel?

    init(title: String, onChange: @escaping (HDMIMixerLevel) -> Void) {
        self.title = title
        self.onChange = onChange
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.textColor = .secondaryLabelColor
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changeVolume)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        valueLabel.alignment = .right
        muteButton.controlSize = .small
        muteButton.bezelStyle = .rounded
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        let stack = NSStackView(views: [titleLabel, slider, valueLabel, muteButton])
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 80),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            valueLabel.widthAnchor.constraint(equalToConstant: 42),
            muteButton.widthAnchor.constraint(equalToConstant: 76),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setAppName(_ name: String) {
        appName = name
        slider.setAccessibilityLabel("\(name) \(title)")
        updateMuteButton()
    }

    func refresh(_ value: HDMIMixerLevel?, enabled: Bool) {
        let display = value ?? HDMIMixerLevel()
        if Int(slider.doubleValue.rounded()) != display.volume {
            slider.integerValue = display.volume
        }
        if level != value || valueLabel.stringValue.isEmpty {
            level = value
            valueLabel.stringValue = value.map { "\($0.volume)%" } ?? "—"
            updateMuteButton()
        }
        slider.isEnabled = enabled && value != nil
        muteButton.isEnabled = slider.isEnabled
    }

    private func updateMuteButton() {
        muteButton.title = level?.muted == true ? "取消靜音" : "靜音"
        muteButton.setAccessibilityLabel("\(appName) \(title) \(muteButton.title)")
    }

    @objc private func changeVolume() {
        let volume = Int(slider.doubleValue.rounded())
        guard let level, volume != level.volume else { return }
        onChange(HDMIMixerLevel(volume: volume, muted: level.muted))
    }

    @objc private func toggleMute() {
        guard let level else { return }
        onChange(HDMIMixerLevel(volume: level.volume, muted: !level.muted))
    }
}
