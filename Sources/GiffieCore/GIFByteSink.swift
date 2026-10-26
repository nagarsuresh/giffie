import Foundation

/// Destination for encoded GIF bytes.
public protocol GIFByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
    func close() throws
}

/// Writes GIF bytes to a file, creating or truncating it.
public final class FileByteSink: GIFByteSink {
    private let handle: FileHandle
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        try handle.write(contentsOf: Data(bytes))
    }

    public func close() throws {
        try handle.close()
    }
}

/// Collects GIF bytes in memory (used by tests and previews).
public final class MemoryByteSink: GIFByteSink {
    public private(set) var data = Data()
    public private(set) var isClosed = false

    public init() {}

    public func write(_ bytes: [UInt8]) throws {
        data.append(contentsOf: bytes)
    }

    public func close() throws {
        isClosed = true
    }
}
