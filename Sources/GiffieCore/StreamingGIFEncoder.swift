import Foundation

/// Encodes an animated GIF incrementally while frames are captured.
///
/// * Only the bounding box of pixels that changed since the previous frame is
///   stored, and unchanged pixels inside that box are transparent, so static
///   parts of the screen cost (almost) nothing.
/// * Identical frames are merged into the previous frame's delay.
/// * Each frame gets its own color table built from just the pixels that
///   changed; UI content with few colors is encoded losslessly.
/// * Delays are derived from capture timestamps on an absolute centisecond
///   grid, so the GIF plays back in real time without drift.
/// * An optional byte budget is enforced *before* a frame is committed, so the
///   finished file never exceeds `Options.maxFileSize` (unless the very first
///   frame alone is bigger).
///
/// Frames are expected as 32-bit BGRA (the native little-endian format of
/// `kCVPixelFormatType_32BGRA`); alpha is ignored. Not thread-safe: drive an
/// instance from a single serial queue.
public final class StreamingGIFEncoder {
    public struct Options: Equatable {
        /// Colors per frame (4...256). Fewer colors make smaller files.
        public var maxColors: Int
        /// Number of times to loop; 0 loops forever.
        public var loopCount: UInt16
        /// Minimum per-frame delay in centiseconds. Browsers slow down
        /// anything below 2 (20 ms), so frames arriving faster are dropped.
        public var minimumFrameDelay: Int
        /// Stop accepting frames once the file would grow beyond this many bytes.
        public var maxFileSize: Int?

        public init(maxColors: Int = 256, loopCount: UInt16 = 0, minimumFrameDelay: Int = 2, maxFileSize: Int? = nil) {
            self.maxColors = maxColors
            self.loopCount = loopCount
            self.minimumFrameDelay = minimumFrameDelay
            self.maxFileSize = maxFileSize
        }
    }

    public enum FrameResult: Equatable {
        /// A new frame was encoded.
        case added
        /// The frame matched the previous one; the previous frame is shown longer.
        case unchanged
        /// The frame arrived less than `minimumFrameDelay` after the previous one and was dropped.
        case tooSoon
        /// Adding the frame would exceed `maxFileSize`; it was not added.
        case sizeLimitReached
    }

    public enum EncoderError: Error, Equatable {
        case invalidDimensions
        case alreadyFinished
        case noFrames
    }

    public struct Summary: Equatable {
        public var width: Int
        public var height: Int
        public var frameCount: Int
        /// Playback duration in seconds.
        public var duration: TimeInterval
        public var byteCount: Int
    }

    private static let graphicControlExtensionSize = 8
    private static let trailerSize = 1

    public let width: Int
    public let height: Int
    public let options: Options

    /// Bytes already handed to the sink.
    public private(set) var bytesWritten = 0
    /// Number of distinct frames encoded so far.
    public private(set) var frameCount = 0
    /// Capture timestamp of the first frame.
    public private(set) var firstTimestamp: TimeInterval?
    /// Capture timestamp of the most recently encoded frame.
    public private(set) var lastFrameTimestamp: TimeInterval?

    /// Size the file would have if it were finished now.
    public var estimatedFileSize: Int {
        bytesWritten + (pending.map { $0.bytes.count + StreamingGIFEncoder.graphicControlExtensionSize } ?? 0)
            + StreamingGIFEncoder.trailerSize
    }

    private struct PendingFrame {
        var bytes: [UInt8]
        var startCentiseconds: Int
        var transparentIndex: UInt8?
    }

    private let sink: GIFByteSink
    private let quantizer = ColorQuantizer()
    private let lzw = LZWEncoder()
    private var previous: [UInt32]
    private var current: [UInt32]
    private var hasPrevious = false
    private var pending: PendingFrame?
    private var isFinished = false

    // Scratch buffers reused between frames.
    private var changedColors: [UInt32] = []
    private var changedMask: [Bool] = []
    private var indices: [UInt8] = []

    public init(sink: GIFByteSink, width: Int, height: Int, options: Options = Options()) throws {
        guard width > 0, height > 0, width <= 0xFFFF, height <= 0xFFFF else {
            throw EncoderError.invalidDimensions
        }
        var options = options
        options.maxColors = min(max(options.maxColors, 4), 256)
        options.minimumFrameDelay = max(options.minimumFrameDelay, 1)
        self.sink = sink
        self.width = width
        self.height = height
        self.options = options
        previous = [UInt32](repeating: 0, count: width * height)
        current = [UInt32](repeating: 0, count: width * height)
        try writeHeader()
    }

    public convenience init(url: URL, width: Int, height: Int, options: Options = Options()) throws {
        try self.init(sink: try FileByteSink(url: url), width: width, height: height, options: options)
    }

    // MARK: - Frames

    /// Adds a captured frame.
    ///
    /// - Parameters:
    ///   - bgra: First byte of the BGRA pixel data.
    ///   - sourceWidth/sourceHeight: Dimensions of the pixel data. If they differ
    ///     from the GIF canvas the overlapping region is used.
    ///   - bytesPerRow: Row stride of the pixel data.
    ///   - timestamp: Capture time in seconds (any monotonic clock).
    @discardableResult
    public func addFrame(bgra: UnsafeRawPointer, sourceWidth: Int, sourceHeight: Int, bytesPerRow: Int,
                         timestamp: TimeInterval) throws -> FrameResult {
        guard !isFinished else { throw EncoderError.alreadyFinished }

        let centiseconds = position(of: timestamp)
        if let pending = pending, centiseconds - pending.startCentiseconds < options.minimumFrameDelay {
            return .tooSoon
        }

        copyIntoCurrent(bgra, sourceWidth: sourceWidth, sourceHeight: sourceHeight, bytesPerRow: bytesPerRow)

        let box: (x: Int, y: Int, w: Int, h: Int)
        if hasPrevious {
            guard let changed = changedBounds() else { return .unchanged }
            box = changed
        } else {
            box = (0, 0, width, height)
        }

        let frameBytes = encodeFrame(box: box, diffAgainstPrevious: hasPrevious)

        if let limit = options.maxFileSize, frameCount > 0 {
            let projected = estimatedFileSize + StreamingGIFEncoder.graphicControlExtensionSize + frameBytes.bytes.count
            if projected > limit { return .sizeLimitReached }
        }

        if let pending = pending {
            try writeFrame(pending, delay: centiseconds - pending.startCentiseconds)
        }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        pending = PendingFrame(bytes: frameBytes.bytes, startCentiseconds: centiseconds,
                               transparentIndex: frameBytes.transparentIndex)
        swap(&previous, &current)
        hasPrevious = true
        frameCount += 1
        lastFrameTimestamp = timestamp
        return .added
    }

    /// Convenience overload for tightly packed BGRA data.
    @discardableResult
    public func addFrame(bgra data: [UInt8], timestamp: TimeInterval) throws -> FrameResult {
        precondition(data.count >= width * height * 4, "Frame data is smaller than the canvas")
        return try data.withUnsafeBytes { raw in
            try addFrame(bgra: raw.baseAddress!, sourceWidth: width, sourceHeight: height, bytesPerRow: width * 4,
                         timestamp: timestamp)
        }
    }

    /// Writes the last frame and the trailer and closes the sink.
    ///
    /// - Parameter endTimestamp: When the recording stopped; the last frame is
    ///   shown until then. Defaults to 100 ms after the last frame.
    @discardableResult
    public func finish(endTimestamp: TimeInterval? = nil) throws -> Summary {
        guard !isFinished else { throw EncoderError.alreadyFinished }
        guard let pending = pending else {
            cancel()
            throw EncoderError.noFrames
        }
        var end = endTimestamp.map(position(of:)) ?? pending.startCentiseconds + 10
        end = max(end, pending.startCentiseconds + options.minimumFrameDelay)
        try writeFrame(pending, delay: end - pending.startCentiseconds)
        self.pending = nil
        try write([0x3B])
        try sink.close()
        isFinished = true
        return Summary(width: width, height: height, frameCount: frameCount, duration: Double(end) / 100,
                       byteCount: bytesWritten)
    }

    /// Abandons the GIF and closes the sink.
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        pending = nil
        try? sink.close()
    }

    // MARK: - Timing

    private func position(of timestamp: TimeInterval) -> Int {
        guard let first = firstTimestamp else { return 0 }
        return Int(((timestamp - first) * 100).rounded())
    }

    // MARK: - Pixels

    private func copyIntoCurrent(_ bgra: UnsafeRawPointer, sourceWidth: Int, sourceHeight: Int, bytesPerRow: Int) {
        let copyWidth = min(width, sourceWidth)
        let copyHeight = min(height, sourceHeight)
        let partial = copyWidth < width || copyHeight < height
        if partial {
            // Keep whatever was there for the uncovered area.
            current.withUnsafeMutableBufferPointer { dst in
                previous.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        current.withUnsafeMutableBufferPointer { dst in
            for y in 0..<copyHeight {
                let row = bgra.advanced(by: y * bytesPerRow)
                let out = dst.baseAddress!.advanced(by: y * width)
                for x in 0..<copyWidth {
                    let pixel = row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                    out[x] = UInt32(littleEndian: pixel) & 0x00FF_FFFF
                }
            }
        }
    }

    /// Bounding box of pixels that differ between `current` and `previous`.
    private func changedBounds() -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        let w = width
        current.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                let rowBytes = w * 4
                for y in 0..<height {
                    let c = cur.baseAddress! + y * w
                    let p = prev.baseAddress! + y * w
                    if memcmp(c, p, rowBytes) == 0 { continue }
                    if y < minY { minY = y }
                    maxY = y
                    var left = 0
                    while left < w && c[left] == p[left] { left += 1 }
                    var right = w - 1
                    while right > left && c[right] == p[right] { right -= 1 }
                    if left < minX { minX = left }
                    if right > maxX { maxX = right }
                }
            }
        }
        guard maxY >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    // MARK: - Encoding

    private func encodeFrame(box: (x: Int, y: Int, w: Int, h: Int), diffAgainstPrevious: Bool)
        -> (bytes: [UInt8], transparentIndex: UInt8?) {
        let pixelCount = box.w * box.h
        changedColors.removeAll(keepingCapacity: true)
        changedColors.reserveCapacity(pixelCount)
        if changedMask.count < pixelCount {
            changedMask = [Bool](repeating: false, count: pixelCount)
        }
        if indices.count != pixelCount {
            indices = [UInt8](repeating: 0, count: pixelCount)
        }

        var hasUnchanged = false
        let w = width
        current.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                changedMask.withUnsafeMutableBufferPointer { mask in
                    var i = 0
                    for y in box.y..<(box.y + box.h) {
                        let rowStart = y * w + box.x
                        for x in 0..<box.w {
                            let color = cur[rowStart + x]
                            let changed = !diffAgainstPrevious || color != prev[rowStart + x]
                            mask[i] = changed
                            if changed {
                                changedColors.append(color)
                            } else {
                                hasUnchanged = true
                            }
                            i += 1
                        }
                    }
                }
            }
        }

        let paletteLimit = hasUnchanged ? options.maxColors - 1 : options.maxColors
        changedColors.withUnsafeBufferPointer { quantizer.buildPalette($0, maxColors: paletteLimit) }
        let palette = quantizer.palette
        let transparentIndex: UInt8? = hasUnchanged ? UInt8(palette.count) : nil
        let entryCount = palette.count + (hasUnchanged ? 1 : 0)
        var tableBits = 1
        while (1 << tableBits) < entryCount { tableBits += 1 }

        // Map pixels to indices.
        indices.withUnsafeMutableBufferPointer { out in
            changedMask.withUnsafeBufferPointer { mask in
                changedColors.withUnsafeBufferPointer { colors in
                    var colorIndex = 0
                    var lastColor: UInt32 = 0xFFFF_FFFF
                    var lastIndex: UInt8 = 0
                    let transparent = transparentIndex ?? 0
                    for i in 0..<pixelCount {
                        if mask[i] {
                            let color = colors[colorIndex]
                            colorIndex += 1
                            if color != lastColor {
                                lastColor = color
                                lastIndex = quantizer.index(of: color)
                            }
                            out[i] = lastIndex
                        } else {
                            out[i] = transparent
                        }
                    }
                }
            }
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(10 + 3 * (1 << tableBits) + pixelCount / 2)
        // Image descriptor.
        bytes.append(0x2C)
        appendUInt16(box.x, to: &bytes)
        appendUInt16(box.y, to: &bytes)
        appendUInt16(box.w, to: &bytes)
        appendUInt16(box.h, to: &bytes)
        bytes.append(0x80 | UInt8(tableBits - 1)) // local color table, not interlaced
        // Local color table, padded to a power of two.
        for entry in palette {
            bytes.append(UInt8((entry >> 16) & 0xFF))
            bytes.append(UInt8((entry >> 8) & 0xFF))
            bytes.append(UInt8(entry & 0xFF))
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 3 * ((1 << tableBits) - palette.count)))
        // Image data.
        indices.withUnsafeBufferPointer { lzw.encode($0, minCodeSize: max(2, tableBits), into: &bytes) }
        return (bytes, transparentIndex)
    }

    // MARK: - Output

    private func writeHeader() throws {
        var bytes: [UInt8] = Array("GIF89a".utf8)
        appendUInt16(width, to: &bytes)
        appendUInt16(height, to: &bytes)
        bytes.append(0x70) // no global color table, 8-bit color resolution
        bytes.append(0)    // background color index
        bytes.append(0)    // pixel aspect ratio
        // NETSCAPE2.0 application extension: loop count.
        bytes.append(contentsOf: [0x21, 0xFF, 0x0B])
        bytes.append(contentsOf: Array("NETSCAPE2.0".utf8))
        bytes.append(contentsOf: [0x03, 0x01])
        appendUInt16(Int(options.loopCount), to: &bytes)
        bytes.append(0)
        try write(bytes)
    }

    private func writeFrame(_ frame: PendingFrame, delay: Int) throws {
        let delay = min(max(delay, 1), 0xFFFF)
        var bytes: [UInt8] = [0x21, 0xF9, 0x04]
        // Disposal method 1 (leave in place) so the next frame draws on top.
        bytes.append((1 << 2) | (frame.transparentIndex == nil ? 0 : 1))
        appendUInt16(delay, to: &bytes)
        bytes.append(frame.transparentIndex ?? 0)
        bytes.append(0)
        bytes.append(contentsOf: frame.bytes)
        try write(bytes)
    }

    private func write(_ bytes: [UInt8]) throws {
        try sink.write(bytes)
        bytesWritten += bytes.count
    }

    @inline(__always)
    private func appendUInt16(_ value: Int, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }
}
