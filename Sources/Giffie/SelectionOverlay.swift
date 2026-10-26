import AppKit
import Carbon

/// The area chosen by the user.
@MainActor
struct CaptureArea {
    let screen: NSScreen
    /// Rect in the screen's local coordinates (points, bottom-left origin).
    let localRect: CGRect

    /// Rect in global AppKit coordinates.
    var globalRect: CGRect {
        localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    /// Rect relative to the display's top-left corner, as ScreenCaptureKit expects.
    var displayRect: CGRect {
        CGRect(x: localRect.minX, y: screen.frame.height - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }
}

/// Frames of the windows currently on screen (front to back), in global
/// AppKit coordinates. Window bounds don't require Screen Recording permission.
@MainActor
enum OnScreenWindows {
    static func frames(excludingPID pid: pid_t) -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            return []
        }
        return info.compactMap { window -> CGRect? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40 else {
                return nil
            }
            // Quartz window bounds use a top-left origin on the primary display.
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
    }
}

/// Drives the full-screen selection overlay on every display: choosing an
/// area, adjusting it, the countdown and the recording frame.
@MainActor
final class SelectionController {
    enum Phase: Equatable {
        case choosing
        case adjusting
        case countdown(Int)
        case recording
    }

    private(set) var phase: Phase = .choosing
    private(set) var activeScreen: NSScreen?
    /// Selection in `activeScreen`'s local coordinates.
    private(set) var selection: CGRect?

    let windowFrames: [CGRect]
    let summary: String
    let pixelScale: (NSScreen) -> CGFloat

    var onConfirm: ((CaptureArea) -> Void)?
    var onCancel: (() -> Void)?
    var onStopRequest: (() -> Void)?

    private var windows: [OverlayWindow] = []

    init(highlightWindows: Bool, summary: String, pixelScale: @escaping (NSScreen) -> CGFloat) {
        windowFrames = highlightWindows ? OnScreenWindows.frames(excludingPID: ProcessInfo.processInfo.processIdentifier) : []
        self.summary = summary
        self.pixelScale = pixelScale
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(screen: screen, controller: self)
            window.contentView = view
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        if let view = keyWindow?.contentView {
            keyWindow?.makeFirstResponder(view)
        }
        NSCursor.crosshair.set()
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
    }

    // MARK: State changes (called by the overlay views)

    func setSelection(_ rect: CGRect?, on screen: NSScreen?) {
        selection = rect
        activeScreen = rect == nil ? nil : screen
        refresh()
    }

    func setPhase(_ newPhase: Phase) {
        phase = newPhase
        if newPhase == .recording {
            for window in windows { window.ignoresMouseEvents = true }
        }
        refresh()
    }

    func confirm() {
        guard phase == .adjusting, let screen = activeScreen, let rect = selection,
              rect.width >= 8, rect.height >= 8 else { return }
        onConfirm?(CaptureArea(screen: screen, localRect: rect))
    }

    func cancel() {
        onCancel?()
    }

    /// Handles keys for whichever overlay window is key. Returns `true` if used.
    func handleKey(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            if phase == .recording { onStopRequest?() } else { cancel() }
            return true
        case kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter:
            switch phase {
            case .adjusting: confirm()
            case .recording: onStopRequest?()
            default: break
            }
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard phase == .adjusting, var rect = selection, let screen = activeScreen else { return true }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let resize = event.modifierFlags.contains(.option)
            switch code {
            case kVK_LeftArrow: if resize { rect.size.width -= step } else { rect.origin.x -= step }
            case kVK_RightArrow: if resize { rect.size.width += step } else { rect.origin.x += step }
            case kVK_UpArrow: if resize { rect.size.height += step; rect.origin.y -= step } else { rect.origin.y += step }
            default: if resize { rect.size.height -= step; rect.origin.y += step } else { rect.origin.y -= step }
            }
            rect.size.width = max(rect.width, 8)
            rect.size.height = max(rect.height, 8)
            setSelection(OverlayView.clamp(rect, to: CGRect(origin: .zero, size: screen.frame.size)), on: screen)
            return true
        default:
            return false
        }
    }

    private func refresh() {
        for window in windows {
            (window.contentView as? OverlayView)?.refresh()
        }
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    }

    private enum DragMode {
        case none
        case creating(origin: CGPoint)
        case moving(offset: CGVector, original: CGRect)
        case resizing(Handle, original: CGRect)
    }

    private weak var controller: SelectionController?
    private let screen: NSScreen
    private var dragMode: DragMode = .none
    private var hoverRect: CGRect?
    private var trackingArea: NSTrackingArea?
    private let toolbar = SelectionToolbar()

    init(screen: NSScreen, controller: SelectionController) {
        self.screen = screen
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        toolbar.isHidden = true
        toolbar.recordButton.target = self
        toolbar.recordButton.action = #selector(recordClicked)
        toolbar.cancelButton.target = self
        toolbar.cancelButton.action = #selector(cancelClicked)
        toolbar.summaryLabel.stringValue = controller.summary
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mySelection: CGRect? {
        guard let controller = controller, controller.activeScreen === screen else { return nil }
        return controller.selection
    }

    func refresh() {
        needsDisplay = true
        layoutToolbar()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let controller = controller else { return }
        let phase = controller.phase
        let selection = mySelection
        let isHoverOnly = selection == nil && phase == .choosing && hoverRect != nil
        let highlight = selection ?? (phase == .choosing && controller.selection == nil ? hoverRect : nil)

        let dim = NSBezierPath(rect: bounds)
        if let highlight = highlight {
            dim.append(NSBezierPath(rect: highlight))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(phase == .recording ? 0.18 : 0.38).setFill()
        dim.fill()

        guard let rect = highlight else {
            if phase == .choosing && controller.selection == nil {
                drawPill("Drag to select an area or click a window  ·  Esc to cancel",
                         centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), fontSize: 15)
            }
            return
        }

        if isHoverOnly {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: rect).fill()
        }

        // Border sits just outside the captured area.
        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        if phase == .recording {
            NSColor.systemRed.setStroke()
            border.stroke()
        } else if isHoverOnly {
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        } else {
            // White line with a dark dash on top stays visible on any background.
            NSColor.white.setStroke()
            border.stroke()
            let dash = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            dash.lineWidth = 2
            dash.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.6).setStroke()
            dash.stroke()
        }

        if phase == .adjusting && selection != nil {
            for handle in Handle.allCases {
                let center = point(for: handle, in: rect)
                let square = NSBezierPath(roundedRect: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8),
                                          xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                square.fill()
                NSColor.black.withAlphaComponent(0.5).setStroke()
                square.lineWidth = 1
                square.stroke()
            }
        }

        if phase != .recording {
            let scale = controller.pixelScale(screen)
            let label = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
            let labelPoint = CGPoint(x: rect.minX + 4, y: min(rect.maxY + 16, bounds.maxY - 16))
            drawPill(label, leftAt: labelPoint, fontSize: 12)
        }

        if case .countdown(let value) = phase {
            drawPill("\(value)", centeredAt: CGPoint(x: rect.midX, y: rect.midY), fontSize: 72)
        }
    }

    private func pillAttributes(_ fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: fontSize > 40 ? .bold : .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    private func drawPill(_ text: String, centeredAt center: CGPoint, fontSize: CGFloat) {
        let string = NSAttributedString(string: text, attributes: pillAttributes(fontSize))
        let size = string.size()
        drawPill(string, in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                    width: size.width, height: size.height))
    }

    private func drawPill(_ text: String, leftAt point: CGPoint, fontSize: CGFloat) {
        let string = NSAttributedString(string: text, attributes: pillAttributes(fontSize))
        let size = string.size()
        drawPill(string, in: NSRect(x: point.x, y: point.y - size.height / 2, width: size.width, height: size.height))
    }

    private func drawPill(_ string: NSAttributedString, in textRect: NSRect) {
        let padX = max(10, textRect.height * 0.5), padY = max(4, textRect.height * 0.2)
        let background = textRect.insetBy(dx: -padX, dy: -padY)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: background, xRadius: background.height / 2, yRadius: background.height / 2).fill()
        string.draw(at: textRect.origin)
    }

    // MARK: Toolbar

    private func layoutToolbar() {
        guard let controller = controller, controller.phase == .adjusting, let rect = mySelection,
              dragModeIsIdle else {
            toolbar.isHidden = true
            return
        }
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < bounds.minY + 8 {
            origin.y = rect.maxY + 34 // above the size label
            if origin.y + size.height > bounds.maxY - 8 {
                origin.y = rect.minY + 12 // inside, at the bottom
            }
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        toolbar.frame = NSRect(origin: origin, size: size)
        toolbar.isHidden = false
    }

    private var dragModeIsIdle: Bool {
        if case .none = dragMode { return true }
        return false
    }

    @objc private func recordClicked() {
        controller?.confirm()
    }

    @objc private func cancelClicked() {
        controller?.cancel()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let controller = controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        if controller.phase == .choosing {
            let global = CGPoint(x: point.x + screen.frame.minX, y: point.y + screen.frame.minY)
            let newHover = controller.windowFrames.first { $0.contains(global) }
                .map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(bounds) }
            if newHover != hoverRect {
                hoverRect = newHover
                needsDisplay = true
            }
        } else if hoverRect != nil {
            hoverRect = nil
            needsDisplay = true
        }
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if hoverRect != nil {
            hoverRect = nil
            needsDisplay = true
        }
    }

    private func updateCursor(at point: CGPoint) {
        guard let controller = controller, controller.phase == .adjusting, let rect = mySelection else {
            if controller?.phase != .recording { NSCursor.crosshair.set() }
            return
        }
        if let handle = hitHandle(at: point, in: rect) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if rect.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller = controller else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        switch controller.phase {
        case .choosing:
            dragMode = .creating(origin: point)
        case .adjusting:
            if let rect = mySelection, let handle = hitHandle(at: point, in: rect) {
                dragMode = .resizing(handle, original: rect)
            } else if let rect = mySelection, rect.contains(point) {
                dragMode = .moving(offset: CGVector(dx: point.x - rect.minX, dy: point.y - rect.minY), original: rect)
                NSCursor.closedHand.set()
            } else {
                dragMode = .creating(origin: point)
            }
        default:
            return
        }
        toolbar.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller = controller else { return }
        let point = OverlayView.clamp(convert(event.locationInWindow, from: nil), to: bounds)
        switch dragMode {
        case .none:
            return
        case .creating(let origin):
            let rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                              width: abs(point.x - origin.x), height: abs(point.y - origin.y)).integral
            if rect.width >= 2 || rect.height >= 2 {
                hoverRect = nil
                if controller.phase != .choosing { controller.setPhase(.choosing) }
                controller.setSelection(rect, on: screen)
            }
        case .moving(let offset, let original):
            var rect = original
            rect.origin = CGPoint(x: (point.x - offset.dx).rounded(), y: (point.y - offset.dy).rounded())
            controller.setSelection(OverlayView.clamp(rect, to: bounds), on: screen)
        case .resizing(let handle, let original):
            controller.setSelection(OverlayView.resize(original, handle: handle, to: point).integral, on: screen)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller = controller, !dragModeIsIdle else { return }
        if case .creating = dragMode {
            if let rect = mySelection, rect.width >= 8, rect.height >= 8 {
                // Keep the dragged rectangle.
            } else {
                // A click: take the window under the cursor, or the whole screen.
                let rect = (hoverRect ?? bounds).intersection(bounds).integral
                controller.setSelection(rect, on: screen)
            }
            hoverRect = nil
        }
        dragMode = .none
        controller.setPhase(.adjusting)
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true {
            super.keyDown(with: event)
        }
    }

    // MARK: Geometry

    private func point(for handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func hitHandle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            let center = self.point(for: handle, in: rect)
            return abs(center.x - point.x) <= 7 && abs(center.y - point.y) <= 7
        }
    }

    private static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .topRight: maxX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        let x0 = min(minX, maxX), x1 = max(minX, maxX), y0 = min(minY, maxY), y1 = max(minY, maxY)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 8), height: max(y1 - y0, 8))
    }

    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var rect = rect
        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }
}

/// Record / Cancel bar shown next to the selection.
final class SelectionToolbar: NSVisualEffectView {
    let recordButton = FirstMouseButton(title: "Record", target: nil, action: nil)
    let cancelButton = FirstMouseButton(title: "Cancel", target: nil, action: nil)
    let summaryLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)

        recordButton.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Record")
        recordButton.imagePosition = .imageLeading
        recordButton.contentTintColor = .systemRed
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.font = .systemFont(ofSize: 13, weight: .semibold)
        recordButton.toolTip = "Start recording (Space)"

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.toolTip = "Cancel (Esc)"

        let hint = NSTextField(labelWithString: "Space to record · Esc to cancel")
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .white
        summaryLabel.font = .systemFont(ofSize: 10)
        summaryLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [hint, summaryLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let stack = NSStackView(views: [recordButton, cancelButton, labels])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
