import AppKit
import Combine
import GiffieCore
import ServiceManagement

enum CaptureScale: String, CaseIterable, Identifiable {
    /// One GIF pixel per screen point: smaller files, ideal for sharing.
    case standard
    /// Native display resolution (2x on Retina screens): crisp but larger.
    case retina

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard (1x)"
        case .retina: return "Retina (2x)"
        }
    }

    func pixelScale(for screen: NSScreen) -> CGFloat {
        switch self {
        case .standard: return 1
        case .retina: return screen.backingScaleFactor
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    static let frameRateChoices = [10, 15, 20, 25, 30]
    static let colorChoices = [256, 128, 64]
    static let countdownChoices = [0, 3, 5]

    private enum Key {
        static let saveFolder = "saveFolderPath"
        static let onboardingDone = "hasCompletedOnboarding"
        static let fps = "framesPerSecond"
        static let scale = "captureScale"
        static let maxDuration = "maxDurationSeconds"
        static let maxFileSize = "maxFileSizeMB"
        static let colors = "maxColors"
        static let cursor = "showsCursor"
        static let countdown = "countdownSeconds"
        static let copy = "copyToClipboardAfterRecording"
        static let showList = "showListAfterRecording"
        static let snapWindows = "highlightWindowsWhileSelecting"
        static let hotKey = "recordHotKey"
        static let hotKeyCleared = "recordHotKeyCleared"
    }

    private let defaults: UserDefaults

    @Published var saveFolder: URL? {
        didSet { defaults.set(saveFolder?.path, forKey: Key.saveFolder) }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingDone) }
    }
    @Published var framesPerSecond: Int {
        didSet { defaults.set(framesPerSecond, forKey: Key.fps) }
    }
    @Published var captureScale: CaptureScale {
        didSet { defaults.set(captureScale.rawValue, forKey: Key.scale) }
    }
    @Published var maxDuration: TimeInterval {
        didSet { defaults.set(maxDuration, forKey: Key.maxDuration) }
    }
    /// 0 = no size limit.
    @Published var maxFileSizeMB: Int {
        didSet { defaults.set(maxFileSizeMB, forKey: Key.maxFileSize) }
    }
    @Published var maxColors: Int {
        didSet { defaults.set(maxColors, forKey: Key.colors) }
    }
    @Published var showsCursor: Bool {
        didSet { defaults.set(showsCursor, forKey: Key.cursor) }
    }
    @Published var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: Key.countdown) }
    }
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Key.copy) }
    }
    @Published var showListAfterRecording: Bool {
        didSet { defaults.set(showListAfterRecording, forKey: Key.showList) }
    }
    @Published var highlightWindows: Bool {
        didSet { defaults.set(highlightWindows, forKey: Key.snapWindows) }
    }
    @Published var hotKey: KeyCombo? {
        didSet {
            if let hotKey = hotKey, let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: Key.hotKey)
                defaults.set(false, forKey: Key.hotKeyCleared)
            } else {
                defaults.removeObject(forKey: Key.hotKey)
                defaults.set(true, forKey: Key.hotKeyCleared)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saveFolder = defaults.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingDone)
        framesPerSecond = defaults.object(forKey: Key.fps) as? Int ?? 15
        captureScale = CaptureScale(rawValue: defaults.string(forKey: Key.scale) ?? "") ?? .standard
        maxDuration = defaults.object(forKey: Key.maxDuration) as? Double ?? RecordingLimits.default.maxDuration
        maxFileSizeMB = defaults.object(forKey: Key.maxFileSize) as? Int ?? 10
        maxColors = defaults.object(forKey: Key.colors) as? Int ?? 256
        showsCursor = defaults.object(forKey: Key.cursor) as? Bool ?? true
        countdownSeconds = defaults.object(forKey: Key.countdown) as? Int ?? 0
        copyToClipboard = defaults.object(forKey: Key.copy) as? Bool ?? false
        showListAfterRecording = defaults.object(forKey: Key.showList) as? Bool ?? true
        highlightWindows = defaults.object(forKey: Key.snapWindows) as? Bool ?? true
        if let data = defaults.data(forKey: Key.hotKey), let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            hotKey = combo
        } else if defaults.bool(forKey: Key.hotKeyCleared) {
            hotKey = nil
        } else {
            hotKey = .defaultRecord
        }
    }

    var limits: RecordingLimits {
        RecordingLimits(maxDuration: maxDuration, maxFileSize: maxFileSizeMB > 0 ? maxFileSizeMB * 1_000_000 : nil)
    }

    /// Suggested location shown during onboarding: ~/Pictures/Giffie.
    static var suggestedSaveFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Giffie", isDirectory: true)
    }

    /// Short summary for the selection toolbar, e.g. "15 fps · 1x · max 30s / 10 MB".
    var recordingSummary: String {
        let scale = captureScale == .standard ? "1x" : "2x"
        let size = maxFileSizeMB > 0 ? " / \(maxFileSizeMB) MB" : ""
        return "\(framesPerSecond) fps · \(scale) · max \(Int(maxDuration))s\(size)"
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Giffie: could not change login item: \(error.localizedDescription)")
            }
        }
    }
}
