import Foundation

/// Limits that end a recording automatically, whichever is hit first.
public struct RecordingLimits: Equatable {
    /// Maximum recording length in seconds.
    public var maxDuration: TimeInterval
    /// Maximum GIF file size in bytes, or `nil` for no size limit.
    public var maxFileSize: Int?

    public init(maxDuration: TimeInterval, maxFileSize: Int?) {
        self.maxDuration = maxDuration
        self.maxFileSize = maxFileSize
    }

    public static let `default` = RecordingLimits(maxDuration: 30, maxFileSize: 10 * 1_000_000)

    public static let durationChoices: [TimeInterval] = [10, 15, 30, 60, 120]
    /// Megabytes; 0 means "no limit".
    public static let fileSizeChoices: [Int] = [5, 10, 15, 25, 50, 0]

    /// Whether a recording that has run for `elapsed` seconds must stop.
    public func durationExceeded(elapsed: TimeInterval) -> Bool {
        elapsed >= maxDuration
    }

    /// Fraction (0...1) of the tightest limit used so far, for progress UI.
    public func progress(elapsed: TimeInterval, fileSize: Int) -> Double {
        var value = maxDuration > 0 ? elapsed / maxDuration : 0
        if let maxFileSize = maxFileSize, maxFileSize > 0 {
            value = max(value, Double(fileSize) / Double(maxFileSize))
        }
        return min(max(value, 0), 1)
    }
}

public enum GiffieFormat {
    /// File name for a recording started at `date`, e.g. `Giffie 2026-10-26 at 20.45.12.gif`.
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Giffie \(formatter.string(from: date)).gif"
    }

    /// `folder/name`, or `folder/name 2.gif`, `name 3.gif`, ... if taken.
    public static func uniqueURL(in folder: URL, fileName: String, fileManager: FileManager = .default) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    /// `m:ss` for a duration in seconds (rounded down).
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Short duration with one decimal, e.g. `4.2s`.
    public static func duration(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", max(0, seconds))
    }

    /// Decimal byte count, e.g. `840 KB`, `3.4 MB`.
    public static func byteCount(_ bytes: Int) -> String {
        let value = Double(bytes)
        if value < 1_000 { return "\(bytes) B" }
        if value < 1_000_000 { return String(format: "%.0f KB", value / 1_000) }
        return String(format: "%.1f MB", value / 1_000_000)
    }
}
