import AppKit
import GiffieCore

/// Runs one recording from start to finish:
/// select area → (countdown) → record → save into the GIF folder.
@MainActor
final class RecordingCoordinator: NSObject {
    enum State: Equatable {
        case idle
        case selecting
        case countingDown
        case starting
        case recording
        case saving
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?
    var onProgress: ((RecordingProgress) -> Void)?
    /// A GIF was saved at the URL. The reason tells whether a limit ended it.
    var onSaved: ((URL, StopReason) -> Void)?
    /// Recording was requested before a save folder was chosen.
    var onNeedsSetup: (() -> Void)?

    private let settings: AppSettings
    private var selection: SelectionController?
    private var recorder: ScreenRecorder?
    private var hud: RecordingHUD?
    private var area: CaptureArea?
    private var countdownTimer: Timer?
    private var countdownRemaining = 0
    private var recordingStartDate = Date()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Hot key / menu bar behaviour: start selecting, cancel the selection, or stop recording.
    func toggle() {
        switch state {
        case .idle: beginSelection()
        case .selecting, .countingDown: cancelSelection()
        case .recording: stop()
        case .starting, .saving: break
        }
    }

    func beginSelection() {
        guard state == .idle else { return }
        guard settings.saveFolder != nil else {
            onNeedsSetup?()
            return
        }
        guard ScreenCapturePermission.isGranted else {
            Alerts.showPermissionNeeded()
            return
        }
        let settings = self.settings
        let controller = SelectionController(
            highlightWindows: settings.highlightWindows,
            summary: settings.recordingSummary,
            pixelScale: { screen in settings.captureScale.pixelScale(for: screen) }
        )
        controller.onConfirm = { [weak self] area in self?.confirm(area) }
        controller.onCancel = { [weak self] in self?.cancelSelection() }
        controller.onStopRequest = { [weak self] in self?.stop() }
        selection = controller
        state = .selecting
        controller.show()
    }

    func cancelSelection() {
        guard state == .selecting || state == .countingDown else { return }
        tearDown()
    }

    /// Stops the recording and saves the GIF.
    func stop() {
        guard state == .recording, let recorder = recorder else { return }
        state = .saving
        hud?.showSaving()
        recorder.stop()
    }

    /// Stops the recording and throws it away.
    func discard() {
        guard state == .recording || state == .starting || state == .saving, let recorder = recorder else { return }
        recorder.onFinish = nil
        recorder.cancel()
        tearDown()
    }

    // MARK: - Steps

    private func confirm(_ area: CaptureArea) {
        guard state == .selecting else { return }
        self.area = area
        if settings.countdownSeconds > 0 {
            state = .countingDown
            countdownRemaining = settings.countdownSeconds
            selection?.setPhase(.countdown(countdownRemaining))
            countdownTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(countdownTick),
                                                  userInfo: nil, repeats: true)
        } else {
            startRecording(area)
        }
    }

    @objc private func countdownTick() {
        guard state == .countingDown else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        countdownRemaining -= 1
        if countdownRemaining > 0 {
            selection?.setPhase(.countdown(countdownRemaining))
        } else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            if let area = area { startRecording(area) }
        }
    }

    private func startRecording(_ area: CaptureArea) {
        guard let displayID = area.screen.displayID else {
            fail(RecorderError.displayNotFound)
            return
        }
        let scale = settings.captureScale.pixelScale(for: area.screen)
        let request = RecordingRequest(
            displayID: displayID,
            sourceRect: area.displayRect,
            pixelWidth: max(1, Int((area.localRect.width * scale).rounded())),
            pixelHeight: max(1, Int((area.localRect.height * scale).rounded())),
            framesPerSecond: settings.framesPerSecond,
            showsCursor: settings.showsCursor,
            maxColors: settings.maxColors,
            limits: settings.limits
        )

        let recorder: ScreenRecorder
        do {
            recorder = try ScreenRecorder(request: request)
        } catch {
            fail(error)
            return
        }
        recorder.onProgress = { [weak self] progress in self?.progressUpdated(progress) }
        recorder.onFinish = { [weak self] result in self?.finished(result) }
        self.recorder = recorder
        state = .starting
        selection?.setPhase(.recording)
        recordingStartDate = Date()

        Task { [weak self] in
            do {
                try await recorder.start()
                self?.didStart()
            } catch {
                recorder.onFinish = nil
                recorder.cancel()
                self?.fail(error)
            }
        }
    }

    private func didStart() {
        guard state == .starting, let area = area else { return }
        state = .recording
        let hud = RecordingHUD(limits: settings.limits)
        hud.onStop = { [weak self] in self?.stop() }
        hud.onCancel = { [weak self] in self?.discard() }
        hud.show(near: area.globalRect, on: area.screen)
        self.hud = hud
    }

    private func progressUpdated(_ progress: RecordingProgress) {
        guard state == .recording else { return }
        hud?.update(progress)
        onProgress?(progress)
    }

    private func finished(_ result: Result<RecordingOutput, Error>) {
        let startDate = recordingStartDate
        tearDown()
        switch result {
        case .success(let output):
            do {
                let url = try save(output, startDate: startDate)
                onSaved?(url, output.reason)
            } catch {
                Alerts.showError("Couldn't save the GIF", error)
            }
        case .failure(let error):
            Alerts.showError("Recording failed", error)
        }
    }

    private func fail(_ error: Error) {
        tearDown()
        if !ScreenCapturePermission.isGranted {
            Alerts.showPermissionNeeded()
        } else {
            Alerts.showError("Couldn't start recording", error)
        }
    }

    private func tearDown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        selection?.close()
        selection = nil
        hud?.close()
        hud = nil
        recorder = nil
        area = nil
        state = .idle
    }

    /// Moves the finished GIF from the temporary folder into the save folder.
    private func save(_ output: RecordingOutput, startDate: Date) throws -> URL {
        let fileManager = FileManager.default
        let folder = settings.saveFolder ?? AppSettings.suggestedSaveFolder
        let fileName = GiffieFormat.fileName(for: startDate)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = GiffieFormat.uniqueURL(in: folder, fileName: fileName)
            try fileManager.moveItem(at: output.url, to: destination)
            return destination
        } catch {
            // Don't lose the recording: fall back to the Desktop.
            let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
            let fallback = GiffieFormat.uniqueURL(in: desktop, fileName: fileName)
            try fileManager.moveItem(at: output.url, to: fallback)
            Alerts.showMessage(
                "Saved to your Desktop",
                "Giffie couldn't write to “\(folder.path)” (\(error.localizedDescription)), so the GIF was saved to your Desktop instead. You can pick another folder in Settings."
            )
            return fallback
        }
    }
}
