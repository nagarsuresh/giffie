import AppKit
import Carbon
import CoreGraphics
import GiffieCore
import ImageIO
import SwiftUI
import XCTest
@testable import Giffie

/// Exercises the app's UI logic and renders its main surfaces to PNGs.
/// Set GIFFIE_SNAPSHOT_DIR to keep the rendered images.
@MainActor
final class GiffieAppTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: - Helpers

    private var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["GIFFIE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func makeSettings() -> AppSettings {
        let suite = "giffie-tests-\(UUID().uuidString)"
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    private func spinRunLoop(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            spinRunLoop(0.05)
        }
        return condition()
    }

    @discardableResult
    private func snapshot(_ view: NSView, size: NSSize, name: String,
                          appearance: NSAppearance.Name = .aqua) throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        spinRunLoop(0.4)
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let directory = snapshotDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func bgra(_ pixels: [UInt32]) -> [UInt8] {
        pixels.flatMap { p in [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), 0xFF] }
    }

    /// Writes a small animated GIF with a moving block.
    private func writeSampleGIF(to url: URL, width: Int, height: Int, frames: Int, color: UInt32) throws {
        let encoder = try StreamingGIFEncoder(url: url, width: width, height: height)
        for i in 0..<frames {
            var pixels = [UInt32](repeating: 0xF2F2F7, count: width * height)
            for y in (height / 3)..<(height / 3 + height / 3) {
                for x in 0..<(width / 4) {
                    let px = (x + i * (width / frames)) % width
                    pixels[y * width + px] = color
                }
            }
            try encoder.addFrame(bgra: bgra(pixels), timestamp: Double(i) * 0.1)
        }
        try encoder.finish(endTimestamp: Double(frames) * 0.1)
    }

    private func keyEvent(_ keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    // MARK: - Settings & shortcuts

    func testSettingsPersist() {
        let suite = "giffie-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.saveFolder)
        XCTAssertEqual(settings.framesPerSecond, 15)
        XCTAssertEqual(settings.limits, RecordingLimits(maxDuration: 30, maxFileSize: 10_000_000))
        XCTAssertEqual(settings.hotKey, .defaultRecord)

        settings.saveFolder = URL(fileURLWithPath: "/tmp/giffie-out", isDirectory: true)
        settings.framesPerSecond = 25
        settings.maxDuration = 60
        settings.maxFileSizeMB = 0
        settings.captureScale = .retina
        settings.hotKey = nil

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.saveFolder?.path, "/tmp/giffie-out")
        XCTAssertEqual(reloaded.framesPerSecond, 25)
        XCTAssertEqual(reloaded.limits, RecordingLimits(maxDuration: 60, maxFileSize: nil))
        XCTAssertEqual(reloaded.captureScale, .retina)
        XCTAssertNil(reloaded.hotKey, "a cleared shortcut must stay cleared")
        defaults.removePersistentDomain(forName: suite)
    }

    func testKeyComboFormattingAndValidation() {
        XCTAssertEqual(KeyCombo.defaultRecord.displayString, "⌥⇧⌘G")
        let event = keyEvent(kVK_ANSI_R, characters: "r", modifiers: [.control, .command])
        let combo = KeyCombo(event: event)
        XCTAssertEqual(combo?.displayString, "⌃⌘R")
        XCTAssertEqual(combo?.hasRequiredModifier, true)
        let shiftOnly = KeyCombo(event: keyEvent(kVK_ANSI_R, characters: "R", modifiers: [.shift]))
        XCTAssertEqual(shiftOnly?.hasRequiredModifier, false)
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)).displayString, "⌃Space")
    }

    func testHotKeyRegistration() {
        let manager = HotKeyManager()
        // An unusual combination that should be free on any machine.
        let combo = KeyCombo(keyCode: UInt32(kVK_F13), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        XCTAssertTrue(manager.register(combo))
        XCTAssertTrue(manager.register(nil))
        manager.unregister()
    }

    // MARK: - Selection overlay

    func testCaptureAreaCoordinates() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let area = CaptureArea(screen: screen, localRect: CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(area.displayRect, CGRect(x: 10, y: screen.frame.height - 220, width: 300, height: 200))
        XCTAssertEqual(area.globalRect.origin.x, screen.frame.minX + 10)
        XCTAssertEqual(area.globalRect.origin.y, screen.frame.minY + 20)
    }

    func testSelectionByDraggingMovingAndResizing() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = SelectionController(highlightWindows: false, summary: "test", pixelScale: { _ in 1 })
        let window = OverlayWindow(screen: screen)
        let view = OverlayView(screen: screen, controller: controller)
        window.contentView = view

        // Drag out a new selection.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 200, y: 180), in: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 250), in: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 300, y: 250), in: window))
        XCTAssertEqual(controller.phase, .adjusting)
        XCTAssertEqual(controller.selection, CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertTrue(controller.activeScreen === screen)

        // Drag inside to move it.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 150, y: 150), in: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 170, y: 160), in: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 170, y: 160), in: window))
        XCTAssertEqual(controller.selection, CGRect(x: 120, y: 110, width: 200, height: 150))

        // Drag the top-right handle to resize it.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 320, y: 260), in: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 400, y: 300), in: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 400, y: 300), in: window))
        XCTAssertEqual(controller.selection, CGRect(x: 120, y: 110, width: 280, height: 190))

        // Arrow keys nudge; Shift moves 10 pt; Option resizes.
        XCTAssertTrue(controller.handleKey(keyEvent(kVK_RightArrow, characters: "\u{F703}")))
        XCTAssertEqual(controller.selection?.origin.x, 121)
        XCTAssertTrue(controller.handleKey(keyEvent(kVK_DownArrow, characters: "\u{F701}", modifiers: [.shift])))
        XCTAssertEqual(controller.selection?.origin.y, 100)
        XCTAssertTrue(controller.handleKey(keyEvent(kVK_RightArrow, characters: "\u{F703}", modifiers: [.option])))
        XCTAssertEqual(controller.selection?.width, 281)
    }

    func testClickSelectsWholeScreenAndSpaceConfirms() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = SelectionController(highlightWindows: false, summary: "test", pixelScale: { _ in 2 })
        let window = OverlayWindow(screen: screen)
        let view = OverlayView(screen: screen, controller: controller)
        window.contentView = view

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 50, y: 50), in: window))
        XCTAssertEqual(controller.selection, view.bounds.integral, "a plain click selects the whole screen")

        var confirmed: CaptureArea?
        var cancelled = false
        var stopRequested = false
        controller.onConfirm = { confirmed = $0 }
        controller.onCancel = { cancelled = true }
        controller.onStopRequest = { stopRequested = true }

        XCTAssertTrue(controller.handleKey(keyEvent(kVK_Space, characters: " ")))
        XCTAssertEqual(confirmed?.localRect, view.bounds.integral)
        XCTAssertFalse(controller.handleKey(keyEvent(kVK_ANSI_A, characters: "a")))

        controller.setPhase(.recording)
        XCTAssertTrue(controller.handleKey(keyEvent(kVK_Space, characters: " ")))
        XCTAssertTrue(stopRequested, "Space stops a running recording")
        XCTAssertFalse(cancelled)

        controller.setPhase(.choosing)
        XCTAssertTrue(controller.handleKey(keyEvent(kVK_Escape, characters: "\u{1B}")))
        XCTAssertTrue(cancelled)
    }

    func testSelectionOverlaySnapshot() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = NSSize(width: min(screen.frame.width, 1280), height: min(screen.frame.height, 800))
        let controller = SelectionController(highlightWindows: false, summary: "15 fps · 1x · max 30s / 10 MB",
                                             pixelScale: { _ in 1 })
        let overlay = OverlayView(screen: screen, controller: controller)
        controller.setSelection(CGRect(x: 360, y: 260, width: 520, height: 300), on: screen)
        controller.setPhase(.adjusting)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.systemTeal.cgColor
        let fakeWindow = NSView(frame: NSRect(x: 300, y: 200, width: 640, height: 420))
        fakeWindow.wantsLayer = true
        fakeWindow.layer?.backgroundColor = NSColor.white.cgColor
        fakeWindow.layer?.cornerRadius = 10
        container.addSubview(fakeWindow)
        overlay.frame = container.bounds
        container.addSubview(overlay)
        overlay.refresh()
        try snapshot(container, size: size, name: "selection-overlay")

        controller.setPhase(.countdown(3))
        overlay.refresh()
        try snapshot(container, size: size, name: "selection-countdown")
    }

    // MARK: - Windows and popover

    func testOnboardingSnapshot() throws {
        let settings = makeSettings()
        let view = NSHostingView(rootView: OnboardingView(settings: settings, onFinish: {}))
        try snapshot(view, size: NSSize(width: 560, height: 470), name: "onboarding")
        try snapshot(NSHostingView(rootView: OnboardingView(settings: settings, onFinish: {})),
                     size: NSSize(width: 560, height: 470), name: "onboarding-dark", appearance: .darkAqua)
    }

    func testPreferencesSnapshot() throws {
        let settings = makeSettings()
        settings.saveFolder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let view = NSHostingView(rootView: PreferencesView(settings: settings, onShortcutRecording: { _ in }))
        try snapshot(view, size: NSSize(width: 500, height: 640), name: "settings")
    }

    func testHistoryListsGIFsWithMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("giffie-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeSampleGIF(to: folder.appendingPathComponent("Giffie 2026-10-26 at 09.15.00.gif"),
                           width: 240, height: 150, frames: 12, color: 0x007AFF)
        try writeSampleGIF(to: folder.appendingPathComponent("Giffie 2026-10-26 at 09.20.00.gif"),
                           width: 320, height: 200, frames: 20, color: 0xFF3B30)
        try writeSampleGIF(to: folder.appendingPathComponent("Giffie 2026-10-26 at 09.25.00.gif"),
                           width: 200, height: 200, frames: 8, color: 0x34C759)
        try Data("not a gif".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let settings = makeSettings()
        settings.saveFolder = folder
        let model = HistoryModel()
        model.setFolder(folder)
        XCTAssertTrue(waitUntil { model.items.count == 3 }, "expected the three GIFs, got \(model.items.count)")

        let red = try XCTUnwrap(model.items.first { $0.name.hasSuffix("09.20.00") })
        XCTAssertEqual(red.pixelWidth, 320)
        XCTAssertEqual(red.pixelHeight, 200)
        XCTAssertEqual(red.frameCount, 20)
        XCTAssertEqual(red.duration, 2.0, accuracy: 0.05)
        XCTAssertNotNil(red.thumbnail)

        model.highlightedURL = model.items.first?.url
        model.notice = StopReason.durationLimit.autoStopMessage
        let actions = HistoryActions(record: {}, openSettings: {}, quit: {})
        let view = NSHostingView(rootView: HistoryView(model: model, settings: settings, actions: actions))
        try snapshot(view, size: NSSize(width: 380, height: 500), name: "gif-list")
        try snapshot(NSHostingView(rootView: HistoryView(model: model, settings: settings, actions: actions)),
                     size: NSSize(width: 380, height: 500), name: "gif-list-dark", appearance: .darkAqua)

        // New files show up automatically through the folder watcher.
        try writeSampleGIF(to: folder.appendingPathComponent("Giffie 2026-10-26 at 09.30.00.gif"),
                           width: 100, height: 100, frames: 4, color: 0xAF52DE)
        XCTAssertTrue(waitUntil { model.items.count == 4 }, "folder watcher did not pick up the new GIF")

        // Copy puts a file URL and the GIF data on the pasteboard.
        let newest = try XCTUnwrap(model.items.first)
        model.copy(newest.url)
        let pasteboard = NSPasteboard.general
        XCTAssertEqual(pasteboard.string(forType: .fileURL), newest.url.absoluteString)
        XCTAssertNotNil(pasteboard.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")))
    }

    func testEmptyHistorySnapshot() throws {
        let settings = makeSettings()
        let model = HistoryModel()
        let actions = HistoryActions(record: {}, openSettings: {}, quit: {})
        try snapshot(NSHostingView(rootView: HistoryView(model: model, settings: settings, actions: actions)),
                     size: NSSize(width: 380, height: 500), name: "gif-list-empty")
    }

    func testRecordingHUDSnapshot() throws {
        let hud = RecordingHUD(limits: .default)
        hud.update(RecordingProgress(elapsed: 7.4, fileSize: 2_300_000, frameCount: 80))
        let content = try XCTUnwrap(hud.contentView)
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        size.width = max(size.width, 200)
        size.height = max(size.height, 40)
        try snapshot(content, size: size, name: "recording-hud", appearance: .darkAqua)
        hud.close()
    }

    // MARK: - Recording (needs Screen Recording permission)

    func testRecorderCapturesScreen() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is not available in this environment")
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(screen.displayID)
        let request = RecordingRequest(
            displayID: displayID,
            sourceRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            pixelWidth: 400,
            pixelHeight: 300,
            framesPerSecond: 15,
            showsCursor: true,
            maxColors: 256,
            limits: RecordingLimits(maxDuration: 2, maxFileSize: nil)
        )
        let recorder = try ScreenRecorder(request: request)
        let result: Result<RecordingOutput, Error> = try await withCheckedThrowingContinuation { continuation in
            recorder.onFinish = { continuation.resume(returning: $0) }
            Task {
                do {
                    try await recorder.start()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let output = try result.get()
        defer { try? FileManager.default.removeItem(at: output.url) }
        XCTAssertEqual(output.summary.width, 400)
        XCTAssertEqual(output.summary.height, 300)
        XCTAssertGreaterThanOrEqual(output.summary.frameCount, 1)
        XCTAssertEqual(output.summary.duration, 2.0, accuracy: 0.2)
        if case .durationLimit = output.reason {} else { XCTFail("expected the time limit to stop the recording") }

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), output.summary.frameCount)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)

        if let directory = snapshotDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent("recording.gif")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: output.url, to: copy)
        }
    }
}
