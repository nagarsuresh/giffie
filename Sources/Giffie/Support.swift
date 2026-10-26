import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission helpers.
@MainActor
enum ScreenCapturePermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time and adds Giffie to the list in
    /// System Settings. Returns the current state.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum AppRelauncher {
    /// Starts a fresh copy of the app once this one has quit; macOS only
    /// applies a newly granted Screen Recording permission after a relaunch.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

@MainActor
enum Alerts {
    static func showPermissionNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Giffie needs Screen Recording permission"
        alert.informativeText = """
        To record your screen, allow Giffie in System Settings → Privacy & Security → Screen Recording. \
        After you switch it on, relaunch Giffie.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch Giffie")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenCapturePermission.request()
            ScreenCapturePermission.openSystemSettings()
        case .alertSecondButtonReturn:
            AppRelauncher.relaunch()
        default:
            break
        }
    }

    static func showError(_ title: String, _ error: Error) {
        showMessage(title, error.localizedDescription)
    }

    static func showMessage(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(ActionMenuItem.fire), keyEquivalent: keyEquivalent)
        self.handler = handler
        target = self
    }

    @objc private func fire() {
        handler?()
    }
}

/// Button that reacts to the first click even when its window isn't key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension NSImage {
    /// Menu bar glyph: a dashed selection frame with a record dot (template image).
    static func giffieStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let frame = rect.insetBy(dx: 1.5, dy: 3)
            let path = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
            path.lineWidth = 1.5
            path.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.black.setStroke()
            path.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6))
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Giffie"
        return image
    }

    /// Menu bar glyph while recording: red circle with a stop square.
    static func giffieRecordingIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7),
                         xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Stop recording"
        return image
    }
}
