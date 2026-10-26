import AppKit
import Combine
import GiffieCore
import SwiftUI

@main
enum GiffieMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let history = HistoryModel()
    private let hotKeys = HotKeyManager()
    private var coordinator: RecordingCoordinator!
    private var statusBar: StatusBarController!
    private let onboardingWindow = WindowPresenter()
    private let settingsWindow = WindowPresenter()
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self)

        coordinator = RecordingCoordinator(settings: settings)
        statusBar = StatusBarController(history: history, settings: settings)

        statusBar.onRecord = { [weak self] in self?.coordinator.beginSelection() }
        statusBar.onStop = { [weak self] in self?.coordinator.stop() }
        statusBar.onOpenSettings = { [weak self] in self?.showSettings() }

        coordinator.onStateChange = { [weak self] state in self?.statusBar.setState(state) }
        coordinator.onProgress = { [weak self] progress in self?.statusBar.updateProgress(progress) }
        coordinator.onNeedsSetup = { [weak self] in self?.showOnboarding() }
        coordinator.onSaved = { [weak self] url, reason in self?.recordingSaved(url, reason: reason) }

        hotKeys.onPress = { [weak self] in self?.coordinator.toggle() }
        registerHotKey(settings.hotKey, reportFailure: false)
        settings.$hotKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] combo in self?.registerHotKey(combo, reportFailure: true) }
            .store(in: &subscriptions)

        settings.$saveFolder
            .removeDuplicates()
            .sink { [weak self] folder in self?.history.setFolder(folder) }
            .store(in: &subscriptions)

        // First thing on a fresh install: ask where GIFs should go.
        if settings.saveFolder == nil || !settings.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching Giffie again from Finder or Spotlight shows the GIF list.
        if settings.saveFolder == nil {
            showOnboarding()
        } else {
            statusBar.showPopover()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.discard()
    }

    // MARK: - Actions

    @objc func showSettings() {
        settingsWindow.show(title: "Giffie Settings") { [settings, hotKeys] in
            PreferencesView(settings: settings) { capturing in
                // Don't trigger a recording while the user types a new shortcut.
                if capturing {
                    hotKeys.unregister()
                } else {
                    hotKeys.register(settings.hotKey)
                }
            }
        }
    }

    @objc func startRecording() {
        coordinator.beginSelection()
    }

    private func showOnboarding() {
        onboardingWindow.show(title: "Welcome to Giffie") { [settings] in
            OnboardingView(settings: settings) { [weak self] in
                self?.onboardingWindow.close()
                self?.statusBar.showPopover()
            }
        }
    }

    private func recordingSaved(_ url: URL, reason: StopReason) {
        history.highlightedURL = url
        history.notice = reason.autoStopMessage
        history.reload()
        if settings.copyToClipboard {
            history.copy(url)
        }
        if settings.showListAfterRecording {
            statusBar.showPopover()
        }
    }

    private func registerHotKey(_ combo: KeyCombo?, reportFailure: Bool) {
        if !hotKeys.register(combo), reportFailure, let combo = combo {
            Alerts.showMessage(
                "Shortcut unavailable",
                "\(combo.displayString) is already used by another app. Please choose a different shortcut."
            )
        }
    }
}

/// Hosts a SwiftUI view in a regular window, reusing it if already open.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show<Content: View>(title: String, content: () -> Content) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Size to the SwiftUI content first so centering uses the real size.
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        if size.width > 0 && size.height > 0 {
            window.setContentSize(size)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Accessory apps have no visible menu bar, but a main menu still provides
/// the standard key equivalents (⌘W, ⌘Q, ⌘C/⌘V, ⌘,) in Giffie's windows.
@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Giffie", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings),
                                           keyEquivalent: ",")
        settingsItem.target = target
        let recordItem = appMenu.addItem(withTitle: "Record Area…", action: #selector(AppDelegate.startRecording),
                                         keyEquivalent: "")
        recordItem.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Giffie", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Giffie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
