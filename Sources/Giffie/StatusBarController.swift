import AppKit
import GiffieCore
import SwiftUI

/// Menu bar icon. Click: show the GIF list (or stop an active recording).
/// Right-click: quick menu.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    var onRecord: (() -> Void)?
    var onStop: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let history: HistoryModel
    private var isRecording = false

    init(history: HistoryModel, settings: AppSettings) {
        self.history = history
        super.init()

        if let button = statusItem.button {
            button.image = .giffieStatusIcon()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Giffie"
        }

        let actions = HistoryActions(
            record: { [weak self] in self?.recordFromPopover() },
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenSettings?()
            },
            quit: { NSApp.terminate(nil) }
        )
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: HistoryView(model: history, settings: settings, actions: actions)
        )
    }

    // MARK: Recording state

    func setState(_ state: RecordingCoordinator.State) {
        guard let button = statusItem.button else { return }
        switch state {
        case .recording, .starting, .saving:
            isRecording = true
            button.image = .giffieRecordingIcon()
            button.toolTip = "Click to stop recording"
            if state == .saving { button.title = " Saving…" }
            if state == .starting { button.title = " 0:00" }
        case .idle, .selecting, .countingDown:
            isRecording = false
            button.image = .giffieStatusIcon()
            button.title = ""
            button.toolTip = "Giffie"
        }
    }

    func updateProgress(_ progress: RecordingProgress) {
        guard isRecording else { return }
        statusItem.button?.title = " " + GiffieFormat.clock(progress.elapsed)
    }

    // MARK: Popover

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        history.reload()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        history.highlightedURL = nil
        history.notice = nil
    }

    private func recordFromPopover() {
        popover.performClose(nil)
        onRecord?()
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if isRecording {
            onStop?()
            return
        }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Record Area…") { [weak self] in self?.onRecord?() })
        menu.addItem(ActionMenuItem("Show Recent GIFs") { [weak self] in self?.showPopover() })
        menu.addItem(ActionMenuItem("Open GIF Folder") { [weak self] in self?.history.openFolder() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…", keyEquivalent: ",") { [weak self] in self?.onOpenSettings?() })
        menu.addItem(ActionMenuItem("About Giffie") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Giffie", keyEquivalent: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
