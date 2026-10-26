import AppKit
import GiffieCore
import QuartzCore

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Small floating bar shown next to the recording area with the elapsed
/// time, the current GIF size, progress towards the limits and a Stop button.
/// It belongs to Giffie, so it is never part of the recording.
@MainActor
final class RecordingHUD: NSObject {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let panel: HUDPanel
    private let limits: RecordingLimits
    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let stopButton = FirstMouseButton(title: "Stop", target: nil, action: nil)
    private let discardButton = FirstMouseButton(title: "", target: nil, action: nil)

    init(limits: RecordingLimits) {
        self.limits = limits
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 48),
                         styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.appearance = NSAppearance(named: .darkAqua)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 70).isActive = true

        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        stopButton.imagePosition = .imageLeading
        stopButton.bezelStyle = .rounded
        stopButton.contentTintColor = .systemRed
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop and save the GIF"

        discardButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Discard")
        discardButton.bezelStyle = .rounded
        discardButton.target = self
        discardButton.action = #selector(discardClicked)
        discardButton.toolTip = "Discard this recording"

        let labels = NSStackView(views: [timeLabel, sizeLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0

        let stack = NSStackView(views: [dot, labels, progress, stopButton, discardButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        update(RecordingProgress(elapsed: 0, fileSize: 0, frameCount: 0))
    }

    /// The HUD's content (used by snapshot tests).
    var contentView: NSView? { panel.contentView }

    /// Places the HUD below the recorded area (or above / inside if there is no room).
    func show(near area: CGRect, on screen: NSScreen) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 14)
        if origin.y < visible.minY + 6 {
            origin.y = area.maxY + 14
            if origin.y + size.height > visible.maxY - 6 {
                origin.y = area.minY + 14
            }
        }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        startPulse()
    }

    func update(_ progress: RecordingProgress) {
        timeLabel.stringValue = "\(GiffieFormat.clock(progress.elapsed)) / \(GiffieFormat.clock(limits.maxDuration))"
        var size = GiffieFormat.byteCount(progress.fileSize)
        if let maxFileSize = limits.maxFileSize {
            size += " / \(GiffieFormat.byteCount(maxFileSize))"
        }
        sizeLabel.stringValue = size
        self.progress.doubleValue = limits.progress(elapsed: progress.elapsed, fileSize: progress.fileSize)
    }

    func showSaving() {
        stopButton.isEnabled = false
        discardButton.isEnabled = false
        timeLabel.stringValue = "Saving…"
        dot.layer?.removeAllAnimations()
    }

    func close() {
        dot.layer?.removeAllAnimations()
        panel.orderOut(nil)
        panel.close()
    }

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func discardClicked() {
        onCancel?()
    }
}
