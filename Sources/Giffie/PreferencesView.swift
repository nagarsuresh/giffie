import AppKit
import Carbon
import GiffieCore
import SwiftUI

@MainActor
struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    /// Called while the shortcut field is capturing keys, so the global hot key can be paused.
    let onShortcutRecording: (Bool) -> Void

    @State private var launchAtLogin: Bool
    @State private var permissionGranted: Bool

    init(settings: AppSettings, onShortcutRecording: @escaping (Bool) -> Void) {
        self.settings = settings
        self.onShortcutRecording = onShortcutRecording
        _launchAtLogin = State(initialValue: settings.launchAtLogin)
        _permissionGranted = State(initialValue: ScreenCapturePermission.isGranted)
    }

    var body: some View {
        Form {
            Section("Save location") {
                HStack(spacing: 10) {
                    Image(nsImage: folderIcon)
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.saveFolder?.lastPathComponent ?? "Not set").font(.headline)
                        Text(settings.saveFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose a folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…", action: chooseFolder)
                    Button("Show") {
                        if let folder = settings.saveFolder { NSWorkspace.shared.open(folder) }
                    }
                    .disabled(settings.saveFolder == nil)
                }
            }

            Section("Recording") {
                Picker("Frame rate", selection: $settings.framesPerSecond) {
                    ForEach(AppSettings.frameRateChoices, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Resolution", selection: $settings.captureScale) {
                    ForEach(CaptureScale.allCases) { Text($0.title).tag($0) }
                }
                Picker("Colors per frame", selection: $settings.maxColors) {
                    ForEach(AppSettings.colorChoices, id: \.self) { count in
                        Text(count == 256 ? "256 (best quality)" : "\(count) (smaller files)").tag(count)
                    }
                }
                Picker("Countdown", selection: $settings.countdownSeconds) {
                    ForEach(AppSettings.countdownChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                }
                Toggle("Show mouse pointer", isOn: $settings.showsCursor)
                Toggle("Highlight windows while selecting", isOn: $settings.highlightWindows)
            }

            Section {
                Picker("Maximum length", selection: $settings.maxDuration) {
                    ForEach(RecordingLimits.durationChoices, id: \.self) { seconds in
                        Text(durationTitle(seconds)).tag(seconds)
                    }
                }
                Picker("Maximum file size", selection: $settings.maxFileSizeMB) {
                    ForEach(RecordingLimits.fileSizeChoices, id: \.self) { megabytes in
                        Text(megabytes == 0 ? "No limit" : "\(megabytes) MB").tag(megabytes)
                    }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Recording stops automatically when either limit is reached. The size limit is exact: a saved GIF never grows past it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("After recording") {
                Toggle("Show the GIF list", isOn: $settings.showListAfterRecording)
                Toggle("Copy the GIF to the clipboard", isOn: $settings.copyToClipboard)
            }

            Section("General") {
                LabeledContent("Record shortcut") {
                    HStack {
                        ShortcutRecorder(combo: $settings.hotKey, onRecordingChange: onShortcutRecording)
                            .frame(width: 150, height: 24)
                        Button("Reset") { settings.hotKey = .defaultRecord }
                            .controlSize(.small)
                    }
                }
                Toggle("Launch Giffie at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        launchAtLogin = settings.launchAtLogin
                    }
                ))
                LabeledContent("Screen Recording") {
                    HStack {
                        Label(permissionGranted ? "Allowed" : "Not allowed",
                              systemImage: permissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(permissionGranted ? .green : .orange)
                        if !permissionGranted {
                            Button("Open System Settings") {
                                ScreenCapturePermission.request()
                                ScreenCapturePermission.openSystemSettings()
                            }
                            .controlSize(.small)
                            Button("Relaunch") { AppRelauncher.relaunch() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .onAppear { permissionGranted = ScreenCapturePermission.isGranted }
    }

    private var folderIcon: NSImage {
        if let folder = settings.saveFolder, FileManager.default.fileExists(atPath: folder.path) {
            return NSWorkspace.shared.icon(forFile: folder.path)
        }
        return NSWorkspace.shared.icon(forFile: NSHomeDirectory())
    }

    private func durationTitle(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        if value % 60 == 0 { return value == 60 ? "1 minute" : "\(value / 60) minutes" }
        return "\(value) seconds"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Giffie saves your animated GIFs"
        panel.directoryURL = settings.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

/// Click, then press the new shortcut. Esc cancels, Delete clears.
@MainActor
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.combo = combo
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        if button.combo != combo { button.combo = combo }
        button.onChange = { newValue in combo = newValue }
        button.onRecordingChange = onRecordingChange
    }
}

final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo? {
        didSet { updateTitle() }
    }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var isRecordingShortcut = false {
        didSet {
            guard oldValue != isRecordingShortcut else { return }
            updateTitle()
            onRecordingChange?(isRecordingShortcut)
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecordingShortcut = false
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { isRecordingShortcut = false }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func toggleRecording() {
        isRecordingShortcut.toggle()
        if isRecordingShortcut { window?.makeFirstResponder(self) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecordingShortcut else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if code == kVK_Escape && flags.isEmpty {
            isRecordingShortcut = false
            return
        }
        if (code == kVK_Delete || code == kVK_ForwardDelete) && flags.isEmpty {
            combo = nil
            onChange?(nil)
            isRecordingShortcut = false
            return
        }
        guard let newCombo = KeyCombo(event: event), newCombo.hasRequiredModifier else {
            NSSound.beep()
            return
        }
        combo = newCombo
        onChange?(newCombo)
        isRecordingShortcut = false
    }

    private func updateTitle() {
        if isRecordingShortcut {
            title = "Type shortcut…"
        } else {
            title = combo?.displayString ?? "Click to set"
        }
    }
}
