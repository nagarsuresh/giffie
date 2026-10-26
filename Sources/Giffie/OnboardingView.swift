import AppKit
import SwiftUI

/// First-run window. Step 1 asks where GIFs should be saved; step 2 covers
/// the Screen Recording permission and how to record.
@MainActor
struct OnboardingView: View {
    @ObservedObject var settings: Settings
    let onFinish: () -> Void

    @State private var step = 0
    @State private var folder: URL
    @State private var folderError: String?
    @State private var permissionGranted: Bool
    @State private var requestedPermission = false

    init(settings: Settings, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.onFinish = onFinish
        _folder = State(initialValue: settings.saveFolder ?? Settings.suggestedSaveFolder)
        _permissionGranted = State(initialValue: ScreenCapturePermission.isGranted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Giffie").font(.largeTitle.weight(.bold))
                    Text("Record any part of your screen as an animated GIF.")
                        .foregroundColor(.secondary)
                }
            }

            if step == 0 {
                folderStep
            } else {
                permissionStep
            }

            Spacer(minLength: 0)

            HStack {
                Text("Step \(step + 1) of 2").font(.caption).foregroundColor(.secondary)
                Spacer()
                if step == 1 {
                    Button("Back") { step = 0 }
                }
                Button(step == 0 ? "Continue" : "Start Using Giffie") {
                    if step == 0 { saveFolderAndContinue() } else { finish() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 560, height: 470)
    }

    // MARK: Step 1 – save location

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should Giffie save your GIFs?").font(.title2.weight(.semibold))
            Text("Every recording is saved to this folder as soon as you stop recording. You can change it later in Settings.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Image(nsImage: folderIcon)
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.lastPathComponent).font(.headline)
                    Text(abbreviatedPath(folder))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Choose…", action: chooseFolder)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 8) {
                quickPick("Pictures/Giffie", Settings.suggestedSaveFolder)
                quickPick("Desktop", FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
                quickPick("Movies", FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first)
            }

            if let folderError = folderError {
                Label(folderError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.callout)
            }
        }
    }

    private func quickPick(_ title: String, _ url: URL?) -> some View {
        Button(title) {
            if let url = url { folder = url }
        }
        .controlSize(.small)
        .disabled(url == nil)
    }

    private var folderIcon: NSImage {
        let path = FileManager.default.fileExists(atPath: folder.path) ? folder.path : NSHomeDirectory()
        return NSWorkspace.shared.icon(forFile: path)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Giffie saves your animated GIFs"
        let existing = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        panel.directoryURL = existing
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            folderError = nil
        }
    }

    private func saveFolderAndContinue() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: folder.path) else {
                folderError = "Giffie can't write to this folder. Please choose another one."
                return
            }
            settings.saveFolder = folder
            folderError = nil
            permissionGranted = ScreenCapturePermission.isGranted
            step = 1
        } catch {
            folderError = error.localizedDescription
        }
    }

    // MARK: Step 2 – permission and tips

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow screen recording").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permissionGranted ? "checkmark.circle.fill" : "rectangle.dashed.badge.record")
                    .font(.system(size: 26))
                    .foregroundColor(permissionGranted ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    if permissionGranted {
                        Text("Screen Recording is allowed. You're all set.")
                    } else {
                        Text("macOS asks you to allow Giffie under System Settings → Privacy & Security → Screen Recording. After switching it on, relaunch Giffie.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(requestedPermission ? "Open System Settings" : "Allow Screen Recording…") {
                                if requestedPermission {
                                    ScreenCapturePermission.openSystemSettings()
                                } else {
                                    requestedPermission = true
                                    permissionGranted = ScreenCapturePermission.request()
                                }
                            }
                            Button("Check Again") { permissionGranted = ScreenCapturePermission.isGranted }
                            if requestedPermission {
                                Button("Relaunch Giffie") {
                                    settings.hasCompletedOnboarding = true
                                    AppRelauncher.relaunch()
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            Text("How to record").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                tip("1", "Click the Giffie icon in the menu bar and choose Record, or press \(settings.hotKey?.displayString ?? "your shortcut").")
                tip("2", "Drag over the part of the screen you want (or click a window). Resize it with the handles.")
                tip("3", "Press Space (or click Record) to start. Press Space, Esc or Stop to finish.")
                tip("4", "Your GIF appears in the menu bar list. Drag it straight into any app.")
            }
        }
    }

    private func tip(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }
}
