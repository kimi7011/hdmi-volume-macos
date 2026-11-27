import AppKit

private final class HDMIVolumePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HDMIVolumeMeter: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.19).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()

        let width = bounds.width * fraction
        if width > 0 {
            let fill = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
            let radius = min(3, width / 2)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: 3).fill()
        }
    }
}

@MainActor
final class HDMIVolumeHUD: NSObject {
    private let size = NSSize(width: 244, height: 63)
    private let speaker = NSImageView()
    private let speakerSymbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
    private let muteSymbol = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
    private let percentLabel = NSTextField(labelWithString: "")
    private let meter = HDMIVolumeMeter()
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 4
        return formatter
    }()
    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(volume: Float32, anchor: NSRect? = nil) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }

        let fraction = volume.isFinite ? max(0, min(1, volume)) : 0
        let value = percentFormatter.string(from: NSNumber(value: fraction)) ?? "\(fraction * 100)%"
        let panel = self.panel ?? makePanel()
        self.panel = panel
        percentLabel.stringValue = value
        speaker.image = fraction == 0 ? muteSymbol : speakerSymbol
        meter.fraction = CGFloat(fraction)
        meter.setAccessibilityValue(NSNumber(value: fraction * 100))
        meter.setAccessibilityValueDescription(value)

        let visible = screen.visibleFrame
        let rightmost = max(visible.minX, visible.maxX - size.width - 12)
        let menuCenter = anchor.flatMap { screen.frame.intersects($0) ? $0.midX : nil }
        let preferredX = menuCenter.map { $0 - size.width / 2 } ?? (visible.maxX - size.width - 52)
        let x = min(rightmost, max(visible.minX, preferredX))
        let y = max(visible.minY, visible.maxY - size.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 1.4, target: self,
                          selector: #selector(hideAfterDelay(_:)), userInfo: nil, repeats: false)
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }

    @objc private func hideAfterDelay(_ timer: Timer) {
        if timer === hideTimer { dismiss() }
    }

    private func makePanel() -> NSPanel {
        let panel = HDMIVolumePanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.title = "HDMI 音量"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let card = NSView(frame: NSRect(origin: .zero, size: size))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: card.frame)
            glass.style = .regular
            glass.cornerRadius = 17
            glass.contentView = card
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView(frame: card.frame)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.appearance = NSAppearance(named: .vibrantDark)
            material.wantsLayer = true
            material.layer?.cornerRadius = 17
            material.layer?.masksToBounds = true
            card.autoresizingMask = [.width, .height]
            material.addSubview(card)
            panel.contentView = material
        }

        let titleLabel = NSTextField(labelWithString: "HDMI 音量")
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        speaker.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        speaker.imageScaling = .scaleProportionallyDown
        speaker.contentTintColor = .labelColor
        speaker.setAccessibilityElement(false)
        meter.setAccessibilityElement(true)
        meter.setAccessibilityRole(.progressIndicator)
        meter.setAccessibilityLabel("HDMI 音量")
        meter.setAccessibilityMinValue(NSNumber(value: 0))
        meter.setAccessibilityMaxValue(NSNumber(value: 100))

        for view in [speaker, titleLabel, percentLabel, meter] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            speaker.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 15),
            speaker.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            speaker.widthAnchor.constraint(equalToConstant: 18),
            speaker.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: speaker.trailingAnchor, constant: 7),
            titleLabel.firstBaselineAnchor.constraint(equalTo: percentLabel.firstBaselineAnchor),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            percentLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -15),
            percentLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            meter.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 15),
            meter.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -15),
            meter.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            meter.heightAnchor.constraint(equalToConstant: 6),
        ])
        return panel
    }
}
