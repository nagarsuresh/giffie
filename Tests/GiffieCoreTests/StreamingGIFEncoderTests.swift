import XCTest
@testable import GiffieCore
#if canImport(ImageIO)
import ImageIO
#endif

/// BGRA test frame helpers. Pixels are given as 0x00RRGGBB.
private func bgra(_ pixels: [UInt32]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(pixels.count * 4)
    for p in pixels {
        out.append(UInt8(p & 0xFF))         // B
        out.append(UInt8((p >> 8) & 0xFF))  // G
        out.append(UInt8((p >> 16) & 0xFF)) // R
        out.append(0xFF)                    // A
    }
    return out
}

/// Deterministic pseudo random numbers (SplitMix64) so tests are reproducible.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A "UI-like" frame: flat background, a few rectangles and a moving box.
private func uiFrame(width: Int, height: Int, step: Int) -> [UInt32] {
    var pixels = [UInt32](repeating: 0xF5F5F7, count: width * height)
    func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        let xs = max(0, x0)..<max(max(0, x0), min(width, x0 + w))
        let ys = max(0, y0)..<max(max(0, y0), min(height, y0 + h))
        for y in ys {
            for x in xs { pixels[y * width + x] = color }
        }
    }
    fill(0, 0, width, 12, 0xDDDDDD)          // title bar
    fill(4, 3, 6, 6, 0xFF5F57)               // traffic lights
    fill(14, 3, 6, 6, 0xFEBC2E)
    fill(24, 3, 6, 6, 0x28C840)
    fill(10, 20, width - 20, 2, 0x007AFF)     // accent line
    fill(5 + step * 3, height / 2, 14, 10, 0x1D1D1F)  // moving box
    return pixels
}

private func encode(width: Int, height: Int, frames: [([UInt32], TimeInterval)], end: TimeInterval? = nil,
                    options: StreamingGIFEncoder.Options = .init()) throws
    -> (summary: StreamingGIFEncoder.Summary, data: Data, results: [StreamingGIFEncoder.FrameResult]) {
    let sink = MemoryByteSink()
    let encoder = try StreamingGIFEncoder(sink: sink, width: width, height: height, options: options)
    var results: [StreamingGIFEncoder.FrameResult] = []
    for (pixels, time) in frames {
        results.append(try encoder.addFrame(bgra: bgra(pixels), timestamp: time))
    }
    let summary = try encoder.finish(endTimestamp: end)
    XCTAssertTrue(sink.isClosed)
    XCTAssertEqual(summary.byteCount, sink.data.count)
    return (summary, sink.data, results)
}

final class LZWEncoderTests: XCTestCase {
    func testRoundTripAcrossCodeSizesAndTableResets() throws {
        var rng = SeededRandom(state: 42)
        let encoder = LZWEncoder()
        for bits in 2...8 {
            for length in [0, 1, 2, 3, 17, 255, 256, 4097, 20_000, 70_000] {
                // Mix runs and noise so both long matches and table growth happen.
                var input = [UInt8]()
                input.reserveCapacity(length)
                while input.count < length {
                    let value = UInt8(Int.random(in: 0..<(1 << bits), using: &rng))
                    let run = Bool.random(using: &rng) ? Int.random(in: 1...40, using: &rng) : 1
                    input.append(contentsOf: repeatElement(value, count: min(run, length - input.count)))
                }
                var output = [UInt8]()
                input.withUnsafeBufferPointer { encoder.encode($0, minCodeSize: bits, into: &output) }
                XCTAssertEqual(Int(output[0]), bits)
                // Strip the code size byte and sub-block framing.
                var payload = [UInt8]()
                var pos = 1
                while true {
                    let n = Int(output[pos]); pos += 1
                    if n == 0 { break }
                    payload.append(contentsOf: output[pos..<(pos + n)])
                    pos += n
                }
                XCTAssertEqual(pos, output.count, "trailing bytes after terminator")
                let decoded = try lzwDecode(payload, minCodeSize: bits, pixelCount: length)
                XCTAssertEqual(decoded, input, "bits=\(bits) length=\(length)")
            }
        }
    }

    func testMinimumCodeSize() {
        XCTAssertEqual(LZWEncoder.minimumCodeSize(forColorCount: 1), 2)
        XCTAssertEqual(LZWEncoder.minimumCodeSize(forColorCount: 4), 2)
        XCTAssertEqual(LZWEncoder.minimumCodeSize(forColorCount: 5), 3)
        XCTAssertEqual(LZWEncoder.minimumCodeSize(forColorCount: 256), 8)
    }
}

final class StreamingGIFEncoderTests: XCTestCase {
    func testFewColorRecordingIsLossless() throws {
        let width = 64, height = 48
        let frames = (0..<10).map { (uiFrame(width: width, height: height, step: $0), Double($0) * 0.1) }
        let (summary, data, results) = try encode(width: width, height: height, frames: frames, end: 1.0)
        XCTAssertEqual(results, Array(repeating: .added, count: 10))
        XCTAssertEqual(summary.frameCount, 10)
        XCTAssertEqual(summary.duration, 1.0, accuracy: 0.001)

        let gif = try decodeGIF(data)
        XCTAssertEqual(gif.width, width)
        XCTAssertEqual(gif.height, height)
        XCTAssertEqual(gif.loopCount, 0)
        XCTAssertEqual(gif.frames.count, 10)
        XCTAssertEqual(gif.totalDelay, 100)
        for (i, frame) in gif.frames.enumerated() {
            XCTAssertEqual(frame.pixels, frames[i].0, "frame \(i) differs")
            XCTAssertEqual(frame.delay, 10)
        }
        // Only the moving box changes, so later frames must be small sub-rectangles.
        for frame in gif.frames.dropFirst() {
            XCTAssertLessThan(frame.rect.w * frame.rect.h, width * height / 4)
            XCTAssertNotNil(frame.transparentIndex)
        }
    }

    func testIdenticalFramesAreMerged() throws {
        let width = 32, height = 32
        let a = uiFrame(width: width, height: height, step: 0)
        let b = uiFrame(width: width, height: height, step: 2)
        let frames: [([UInt32], TimeInterval)] = [(a, 10.0), (a, 10.1), (a, 10.2), (b, 10.5), (b, 10.6)]
        let (summary, data, results) = try encode(width: width, height: height, frames: frames, end: 11.0)
        XCTAssertEqual(results, [.added, .unchanged, .unchanged, .added, .unchanged])
        XCTAssertEqual(summary.frameCount, 2)
        let gif = try decodeGIF(data)
        XCTAssertEqual(gif.frames.map(\.delay), [50, 50])
        XCTAssertEqual(gif.frames[1].pixels, b)
    }

    func testDelaysFollowTimestampsWithoutDrift() throws {
        let width = 24, height = 24
        // ~30 fps: 33.3 ms steps must alternate 3/4 cs and sum to the real duration.
        let frames = (0..<31).map { (uiFrame(width: width, height: height, step: $0 % 5), 5.0 + Double($0) / 30.0) }
        let (summary, data, _) = try encode(width: width, height: height, frames: frames, end: 5.0 + 31.0 / 30.0)
        let gif = try decodeGIF(data)
        XCTAssertEqual(gif.totalDelay, 103)
        XCTAssertEqual(summary.duration, 1.03, accuracy: 0.001)
        XCTAssertTrue(gif.frames.allSatisfy { $0.delay >= 2 })
    }

    func testFramesArrivingTooFastAreDropped() throws {
        let width = 16, height = 16
        let frames: [([UInt32], TimeInterval)] = [
            (uiFrame(width: width, height: height, step: 0), 0),
            (uiFrame(width: width, height: height, step: 1), 0.005),
            (uiFrame(width: width, height: height, step: 2), 0.05),
        ]
        let (summary, data, results) = try encode(width: width, height: height, frames: frames, end: 0.1)
        XCTAssertEqual(results, [.added, .tooSoon, .added])
        XCTAssertEqual(summary.frameCount, 2)
        let gif = try decodeGIF(data)
        XCTAssertEqual(gif.frames.map(\.delay), [5, 5])
        XCTAssertEqual(gif.frames[1].pixels, frames[2].0)
    }

    func testManyColorFrameIsCloseToSource() throws {
        let width = 96, height = 64
        var rng = SeededRandom(state: 7)
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // Smooth gradient plus noise: thousands of distinct colors.
                let r = UInt32(min(255, x * 255 / width + Int.random(in: 0...6, using: &rng)))
                let g = UInt32(min(255, y * 255 / height + Int.random(in: 0...6, using: &rng)))
                let b = UInt32((x + y) * 255 / (width + height))
                pixels[y * width + x] = r << 16 | g << 8 | b
            }
        }
        let (_, data, _) = try encode(width: width, height: height, frames: [(pixels, 0)])
        let gif = try decodeGIF(data)
        XCTAssertEqual(gif.frames.count, 1)
        XCTAssertLessThanOrEqual(gif.frames[0].colorTableSize, 256)
        var totalError = 0
        var worst = 0
        for (a, b) in zip(gif.frames[0].pixels, pixels) {
            let dr = abs(Int(a >> 16 & 0xFF) - Int(b >> 16 & 0xFF))
            let dg = abs(Int(a >> 8 & 0xFF) - Int(b >> 8 & 0xFF))
            let db = abs(Int(a & 0xFF) - Int(b & 0xFF))
            totalError += dr + dg + db
            worst = max(worst, max(dr, max(dg, db)))
        }
        let meanError = Double(totalError) / Double(pixels.count * 3)
        XCTAssertLessThan(meanError, 6, "mean per-channel error too high")
        XCTAssertLessThan(worst, 48, "worst per-channel error too high")
    }

    func testColorLimitIsRespected() throws {
        let width = 64, height = 64
        var pixels = [UInt32](repeating: 0, count: width * height)
        for i in pixels.indices { pixels[i] = UInt32(i * 2654435761 & 0xFFFFFF) }
        let options = StreamingGIFEncoder.Options(maxColors: 32)
        let (_, data, _) = try encode(width: width, height: height, frames: [(pixels, 0)], options: options)
        let gif = try decodeGIF(data)
        XCTAssertEqual(gif.frames[0].colorTableSize, 32)
        XCTAssertLessThanOrEqual(Set(gif.frames[0].pixels).count, 32)
    }

    func testSizeLimitIsNeverExceeded() throws {
        let width = 80, height = 60
        var rng = SeededRandom(state: 99)
        let limit = 40_000
        let sink = MemoryByteSink()
        let encoder = try StreamingGIFEncoder(sink: sink, width: width, height: height,
                                              options: .init(maxFileSize: limit))
        var stoppedAt: Int?
        for i in 0..<200 {
            let noise = (0..<(width * height)).map { _ in UInt32.random(in: 0...0xFFFFFF, using: &rng) }
            let result = try encoder.addFrame(bgra: bgra(noise), timestamp: Double(i) * 0.1)
            XCTAssertLessThanOrEqual(encoder.estimatedFileSize, limit)
            if result == .sizeLimitReached {
                stoppedAt = i
                break
            }
        }
        XCTAssertNotNil(stoppedAt, "limit should have been reached")
        let summary = try encoder.finish(endTimestamp: Double(stoppedAt!) * 0.1)
        XCTAssertLessThanOrEqual(summary.byteCount, limit)
        XCTAssertEqual(sink.data.count, summary.byteCount)
        XCTAssertEqual(try decodeGIF(sink.data).frames.count, summary.frameCount)
    }

    func testEstimatedSizeMatchesFinalSize() throws {
        let width = 40, height = 30
        let sink = MemoryByteSink()
        let encoder = try StreamingGIFEncoder(sink: sink, width: width, height: height)
        for i in 0..<6 {
            try encoder.addFrame(bgra: bgra(uiFrame(width: width, height: height, step: i)), timestamp: Double(i) * 0.2)
        }
        let estimate = encoder.estimatedFileSize
        let summary = try encoder.finish(endTimestamp: 1.2)
        XCTAssertEqual(summary.byteCount, estimate)
    }

    func testSmallerSourceFrameKeepsUncoveredArea() throws {
        let width = 20, height = 20
        let sink = MemoryByteSink()
        let encoder = try StreamingGIFEncoder(sink: sink, width: width, height: height)
        let full = [UInt32](repeating: 0x336699, count: width * height)
        try encoder.addFrame(bgra: bgra(full), timestamp: 0)
        // A 10x10 red source with a padded stride.
        var small = [UInt8]()
        for _ in 0..<10 {
            for _ in 0..<10 { small.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF]) }
            small.append(contentsOf: [UInt8](repeating: 0xAB, count: 16)) // row padding
        }
        let result = try small.withUnsafeBytes {
            try encoder.addFrame(bgra: $0.baseAddress!, sourceWidth: 10, sourceHeight: 10, bytesPerRow: 56, timestamp: 0.1)
        }
        XCTAssertEqual(result, .added)
        try encoder.finish(endTimestamp: 0.2)
        let gif = try decodeGIF(sink.data)
        let last = gif.frames[1]
        XCTAssertEqual(last.rect.w, 10)
        XCTAssertEqual(last.rect.h, 10)
        XCTAssertEqual(last.pixels[0], 0xFF0000)
        XCTAssertEqual(last.pixels[9 * width + 9], 0xFF0000)
        XCTAssertEqual(last.pixels[10], 0x336699)
        XCTAssertEqual(last.pixels[19 * width + 19], 0x336699)
    }

    func testFinishWithoutFramesThrows() throws {
        let encoder = try StreamingGIFEncoder(sink: MemoryByteSink(), width: 4, height: 4)
        XCTAssertThrowsError(try encoder.finish()) { error in
            XCTAssertEqual(error as? StreamingGIFEncoder.EncoderError, .noFrames)
        }
    }

    func testInvalidDimensionsThrow() {
        XCTAssertThrowsError(try StreamingGIFEncoder(sink: MemoryByteSink(), width: 0, height: 10))
        XCTAssertThrowsError(try StreamingGIFEncoder(sink: MemoryByteSink(), width: 70_000, height: 10))
    }

    func testWritesFileToDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("giffie-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("out.gif")
        let encoder = try StreamingGIFEncoder(url: url, width: 30, height: 20)
        for i in 0..<4 {
            try encoder.addFrame(bgra: bgra(uiFrame(width: 30, height: 20, step: i)), timestamp: Double(i) * 0.25)
        }
        let summary = try encoder.finish(endTimestamp: 1)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, summary.byteCount)
        XCTAssertEqual(try decodeGIF(data).frames.count, 4)
    }

    #if canImport(ImageIO)
    /// Cross-check with Apple's decoder: frame count, delays and pixels.
    func testImageIODecodesOutput() throws {
        let width = 64, height = 48
        let frames = (0..<8).map { (uiFrame(width: width, height: height, step: $0), Double($0) * 0.08) }
        let (_, data, _) = try encode(width: width, height: height, frames: frames, end: 0.64)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 8)
        for index in 0..<8 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            XCTAssertEqual(delay ?? 0, 0.08, accuracy: 0.001)

            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, height)
            let space = CGColorSpaceCreateDeviceRGB()
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for (i, expected) in frames[index].0.enumerated() {
                let r = UInt32(buffer[i * 4]), g = UInt32(buffer[i * 4 + 1]), b = UInt32(buffer[i * 4 + 2])
                if (r << 16 | g << 8 | b) != expected {
                    XCTFail("ImageIO pixel mismatch in frame \(index) at \(i)")
                    return
                }
            }
        }
    }
    #endif

    /// Writes sample GIFs for manual inspection when GIFFIE_SAMPLE_DIR is set.
    func testWriteSamplesIfRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["GIFFIE_SAMPLE_DIR"] else { return }
        let folder = URL(fileURLWithPath: dir)
        let width = 120, height = 80
        let encoder = try StreamingGIFEncoder(url: folder.appendingPathComponent("ui.gif"), width: width, height: height)
        for i in 0..<30 {
            try encoder.addFrame(bgra: bgra(uiFrame(width: width, height: height, step: i)), timestamp: Double(i) / 15)
        }
        try encoder.finish(endTimestamp: 2)

        var rng = SeededRandom(state: 3)
        let gradient = try StreamingGIFEncoder(url: folder.appendingPathComponent("gradient.gif"), width: width, height: height)
        for i in 0..<10 {
            var pixels = [UInt32](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let r = UInt32((x + i * 8) * 255 / (width + 80))
                    let g = UInt32(y * 255 / height)
                    let b = UInt32(Int.random(in: 100...140, using: &rng))
                    pixels[y * width + x] = r << 16 | g << 8 | b
                }
            }
            try gradient.addFrame(bgra: bgra(pixels), timestamp: Double(i) * 0.1)
        }
        try gradient.finish(endTimestamp: 1)
    }
}

final class RecordingLimitsTests: XCTestCase {
    func testDurationAndProgress() {
        let limits = RecordingLimits(maxDuration: 30, maxFileSize: 10_000_000)
        XCTAssertFalse(limits.durationExceeded(elapsed: 29.9))
        XCTAssertTrue(limits.durationExceeded(elapsed: 30))
        XCTAssertEqual(limits.progress(elapsed: 15, fileSize: 1_000_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(limits.progress(elapsed: 3, fileSize: 8_000_000), 0.8, accuracy: 0.0001)
        XCTAssertEqual(limits.progress(elapsed: 90, fileSize: 0), 1)
        let unlimitedSize = RecordingLimits(maxDuration: 10, maxFileSize: nil)
        XCTAssertEqual(unlimitedSize.progress(elapsed: 5, fileSize: 999_999_999), 0.5, accuracy: 0.0001)
    }

    func testFormatting() {
        let date = Date(timeIntervalSince1970: 1_793_047_512) // 2026-10-26 20:45:12 UTC
        XCTAssertEqual(GiffieFormat.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!),
                       "Giffie 2026-10-26 at 20.45.12.gif")
        XCTAssertEqual(GiffieFormat.clock(0), "0:00")
        XCTAssertEqual(GiffieFormat.clock(7.9), "0:07")
        XCTAssertEqual(GiffieFormat.clock(75), "1:15")
        XCTAssertEqual(GiffieFormat.byteCount(512), "512 B")
        XCTAssertEqual(GiffieFormat.byteCount(840_000), "840 KB")
        XCTAssertEqual(GiffieFormat.byteCount(3_400_000), "3.4 MB")
        XCTAssertEqual(GiffieFormat.duration(4.25), "4.2s")
    }

    func testUniqueURL() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("giffie-unique-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = GiffieFormat.uniqueURL(in: folder, fileName: "a.gif")
        XCTAssertEqual(first.lastPathComponent, "a.gif")
        _ = FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = GiffieFormat.uniqueURL(in: folder, fileName: "a.gif")
        XCTAssertEqual(second.lastPathComponent, "a 2.gif")
        _ = FileManager.default.createFile(atPath: second.path, contents: Data())
        XCTAssertEqual(GiffieFormat.uniqueURL(in: folder, fileName: "a.gif").lastPathComponent, "a 3.gif")
    }
}

final class EncoderBenchmarkTests: XCTestCase {
    /// Rough real-time check; only runs when GIFFIE_BENCHMARK is set (use a release build).
    func testThroughput() throws {
        guard ProcessInfo.processInfo.environment["GIFFIE_BENCHMARK"] != nil else { return }
        let width = 1440, height = 900
        for scenario in ["ui", "full-motion"] {
            let encoder = try StreamingGIFEncoder(sink: MemoryByteSink(), width: width, height: height)
            var frame = [UInt8](repeating: 0, count: width * height * 4)
            let start = Date()
            let count = 30
            for i in 0..<count {
                for y in 0..<height {
                    for x in 0..<width {
                        let o = (y * width + x) * 4
                        if scenario == "ui" {
                            let inBox = x >= 100 + i * 10 && x < 300 + i * 10 && y >= 200 && y < 300
                            let v: UInt8 = inBox ? 30 : (y < 40 ? 220 : 245)
                            frame[o] = v; frame[o + 1] = v; frame[o + 2] = v
                        } else {
                            frame[o] = UInt8((x + i * 7) & 0xFF)
                            frame[o + 1] = UInt8((y * 2 + i * 3) & 0xFF)
                            frame[o + 2] = UInt8(((x ^ y) + i) & 0xFF)
                        }
                        frame[o + 3] = 255
                    }
                }
                try encoder.addFrame(bgra: frame, timestamp: Double(i) / 15)
            }
            let summary = try encoder.finish(endTimestamp: Double(count) / 15)
            let elapsed = Date().timeIntervalSince(start)
            print("[benchmark] \(scenario): \(count) frames \(width)x\(height) in \(String(format: "%.2f", elapsed))s "
                  + "(\(String(format: "%.1f", Double(count) / elapsed)) fps incl. frame synthesis), \(summary.byteCount) bytes")
        }
    }
}
