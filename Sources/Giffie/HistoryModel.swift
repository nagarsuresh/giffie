import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A GIF in the save folder.
struct GIFItem: Identifiable {
    let url: URL
    let date: Date
    let fileSize: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
    let duration: TimeInterval
    let thumbnail: NSImage?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Reads GIF metadata and thumbnails off the main thread.
enum GIFLibrary {
    static let maxItems = 60

    static func scan(folder: URL, previous: [URL: GIFItem]) -> [GIFItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let candidates = urls.compactMap { url -> (URL, Date, Int)? in
            guard url.pathExtension.lowercased() == "gif",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
            return (url, date, values.fileSize ?? 0)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(maxItems)

        return candidates.compactMap { url, date, size in
            if let cached = previous[url], cached.fileSize == size, cached.date == date {
                return cached
            }
            return readItem(url: url, date: date, fileSize: size)
        }
    }

    static func readItem(url: URL, date: Date, fileSize: Int) -> GIFItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { continue }
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            duration += delay
        }

        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = first?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = first?[kCGImagePropertyPixelHeight] as? Int ?? 0

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .map { NSImage(cgImage: $0, size: .zero) }

        return GIFItem(url: url, date: date, fileSize: fileSize, pixelWidth: width, pixelHeight: height,
                       frameCount: count, duration: duration, thumbnail: thumbnail)
    }
}

/// The list of recent GIFs shown in the menu bar popover. Watches the save
/// folder so files added or removed in Finder show up immediately.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var items: [GIFItem] = []
    @Published private(set) var folder: URL?
    /// The most recent recording, highlighted in the list.
    @Published var highlightedURL: URL?
    /// One-line notice shown above the list (e.g. "Stopped at the time limit").
    @Published var notice: String?

    private var cache: [URL: GIFItem] = [:]
    private var monitor: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var scanGeneration = 0

    func setFolder(_ url: URL?) {
        guard url != folder else { return }
        folder = url
        cache = [:]
        items = []
        startMonitoring()
        reload()
    }

    func reload() {
        guard let folder = folder else {
            items = []
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        let previous = cache
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = GIFLibrary.scan(folder: folder, previous: previous)
            await self?.apply(items, generation: generation)
        }
    }

    private func apply(_ newItems: [GIFItem], generation: Int) {
        guard generation == scanGeneration else { return }
        items = newItems
        cache = Dictionary(newItems.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = nil
        guard let folder = folder else { return }
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        monitor = source
    }

    // MARK: - Actions

    func open(_ item: GIFItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: GIFItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: url) {
            pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        pasteboard.writeObjects([pasteboardItem])
    }

    func trash(_ item: GIFItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            Alerts.showError("Couldn't move the GIF to the Trash", error)
        }
        items.removeAll { $0.url == item.url }
        reload()
    }

    func openFolder() {
        guard let folder = folder else { return }
        NSWorkspace.shared.open(folder)
    }
}
