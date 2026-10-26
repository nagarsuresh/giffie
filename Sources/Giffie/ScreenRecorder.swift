import AppKit
import CoreMedia
import GiffieCore
@preconcurrency import ScreenCaptureKit

/// What to record.
struct RecordingRequest {
    var displayID: CGDirectDisplayID
    /// Area to capture in display points, relative to the display's top-left corner.
    var sourceRect: CGRect
    /// GIF canvas size in pixels.
    var pixelWidth: Int
    var pixelHeight: Int
    var framesPerSecond: Int
    var showsCursor: Bool
    var maxColors: Int
    var limits: RecordingLimits
    /// Leave Giffie's own windows (overlay, toolbar, HUD) out of the GIF.
    var excludesOwnWindows = true
}

struct RecordingProgress {
    var elapsed: TimeInterval
    var fileSize: Int
    var frameCount: Int
}

enum StopReason {
    case user
    case durationLimit
    case sizeLimit
    case streamStopped(Error?)

    var autoStopMessage: String? {
        switch self {
        case .user: return nil
        case .durationLimit: return "Stopped at the time limit."
        case .sizeLimit: return "Stopped at the file size limit."
        case .streamStopped: return "Recording ended by the system."
        }
    }
}

struct RecordingOutput {
    /// Finished GIF in a temporary location.
    var url: URL
    var summary: StreamingGIFEncoder.Summary
    var reason: StopReason
}

enum RecorderError: LocalizedError {
    case displayNotFound
    case nothingRecorded(Error?)

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The selected display is no longer available."
        case .nothingRecorded(let underlying):
            if let underlying = underlying {
                return "Nothing was recorded: \(underlying.localizedDescription)"
            }
            return "Nothing was recorded. Try recording for a little longer."
        }
    }
}

/// Captures an area of a display with ScreenCaptureKit and streams every
/// frame straight into a `StreamingGIFEncoder`.
///
/// All capture and encoding state lives on a private serial queue; callbacks
/// are delivered on the main actor. That confinement is what makes the
/// `@unchecked Sendable` conformance safe.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let request: RecordingRequest
    let temporaryURL: URL

    /// Called a few times per second while recording.
    var onProgress: (@MainActor (RecordingProgress) -> Void)?
    /// Called exactly once when the recording has ended (by `stop()`, a limit or the system).
    var onFinish: (@MainActor (Result<RecordingOutput, Error>) -> Void)?

    private let queue = DispatchQueue(label: "app.giffie.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var encoder: StreamingGIFEncoder?
    private var timer: DispatchSourceTimer?
    private var captureStartTime: TimeInterval?
    private var isDone = false

    init(request: RecordingRequest) throws {
        self.request = request
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Giffie-\(UUID().uuidString).gif")
        encoder = try StreamingGIFEncoder(
            url: temporaryURL,
            width: request.pixelWidth,
            height: request.pixelHeight,
            options: .init(maxColors: request.maxColors, maxFileSize: request.limits.maxFileSize)
        )
        super.init()
    }

    private static func hostTime() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    // MARK: - Control

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
            throw RecorderError.displayNotFound
        }
        // Keep Giffie's own overlay, toolbar and HUD out of the recording.
        // Excluding the app also covers windows opened later (the HUD); if the
        // app isn't listed, fall back to excluding the windows open right now.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter: SCContentFilter
        if !request.excludesOwnWindows {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if !ownApps.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        } else {
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }

        let config = SCStreamConfiguration()
        config.sourceRect = request.sourceRect
        config.width = request.pixelWidth
        config.height = request.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, request.framesPerSecond)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = request.showsCursor
        config.queueDepth = 6
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.async {
            self.stream = stream
            self.captureStartTime = ScreenRecorder.hostTime()
            self.startProgressTimer()
            if self.isDone {
                // Stopped while starting up.
                stream.stopCapture { _ in }
                self.stream = nil
            }
        }
    }

    /// Ends the recording and saves what was captured.
    func stop() {
        let now = ScreenRecorder.hostTime()
        queue.async { self.finish(reason: .user, endTime: now) }
    }

    /// Ends the recording and throws the GIF away.
    func cancel() {
        queue.async {
            guard !self.isDone else { return }
            self.isDone = true
            self.timer?.cancel()
            self.timer = nil
            self.stream?.stopCapture { _ in }
            self.stream = nil
            self.encoder?.cancel()
            self.encoder = nil
            try? FileManager.default.removeItem(at: self.temporaryURL)
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isDone, let encoder = encoder, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let timestamp = sampleBuffer.presentationTimeStamp.seconds
        if let first = encoder.firstTimestamp, timestamp - first >= request.limits.maxDuration {
            finish(reason: .durationLimit, endTime: first + request.limits.maxDuration)
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        do {
            let result = try encoder.addFrame(
                bgra: base,
                sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
                sourceHeight: CVPixelBufferGetHeight(pixelBuffer),
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                timestamp: timestamp
            )
            if result == .sizeLimitReached {
                finish(reason: .sizeLimit, endTime: timestamp)
            }
        } catch {
            finish(reason: .streamStopped(error), endTime: timestamp)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            // The stream is already gone; don't try to stop it again.
            self.stream = nil
            self.finish(reason: .streamStopped(error), endTime: nil)
        }
    }

    // MARK: - Internals (capture queue only)

    private func startProgressTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !isDone, let encoder = encoder else { return }
        let now = ScreenRecorder.hostTime()
        let origin = encoder.firstTimestamp ?? captureStartTime ?? now
        let elapsed = max(0, now - origin)
        if elapsed >= request.limits.maxDuration {
            finish(reason: .durationLimit, endTime: origin + request.limits.maxDuration)
            return
        }
        let progress = RecordingProgress(elapsed: elapsed, fileSize: encoder.estimatedFileSize,
                                         frameCount: encoder.frameCount)
        if let onProgress = onProgress {
            Task { @MainActor in onProgress(progress) }
        }
    }

    private func finish(reason: StopReason, endTime: TimeInterval?) {
        guard !isDone else { return }
        isDone = true
        timer?.cancel()
        timer = nil
        stream?.stopCapture { _ in }
        stream = nil

        let result: Result<RecordingOutput, Error>
        if let encoder = encoder {
            do {
                var end = endTime ?? ScreenRecorder.hostTime()
                if let first = encoder.firstTimestamp {
                    end = min(end, first + request.limits.maxDuration)
                }
                let summary = try encoder.finish(endTimestamp: end)
                result = .success(RecordingOutput(url: temporaryURL, summary: summary, reason: reason))
            } catch StreamingGIFEncoder.EncoderError.noFrames {
                if case .streamStopped(let error) = reason {
                    result = .failure(RecorderError.nothingRecorded(error))
                } else {
                    result = .failure(RecorderError.nothingRecorded(nil))
                }
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(RecorderError.nothingRecorded(nil))
        }
        encoder = nil
        if case .failure = result {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        if let onFinish = onFinish {
            Task { @MainActor in onFinish(result) }
        }
    }
}
