import Foundation

/// Variable-length-code LZW compressor for GIF image data.
///
/// The code-size bookkeeping follows the classic `compress`/GIFENCOD
/// algorithm (as used by most GIF writers) so the output is readable by every
/// decoder. The string table is a direct-indexed `prefix << 8 | suffix`
/// lookup with generation stamps, so clearing the table is O(1).
///
/// An instance owns ~4 MB of table memory; reuse it across frames.
public final class LZWEncoder {
    private static let maxBits = 12
    private static let maxCodes = 1 << maxBits

    private var codes: [UInt16]
    private var stamps: [UInt16]
    private var generation: UInt16 = 0

    // Bit packer state.
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0
    private var block = [UInt8](repeating: 0, count: 255)
    private var blockLength = 0

    public init() {
        codes = [UInt16](repeating: 0, count: LZWEncoder.maxCodes << 8)
        stamps = [UInt16](repeating: 0, count: LZWEncoder.maxCodes << 8)
    }

    /// Smallest valid LZW minimum code size for a color table with `colorCount` entries.
    public static func minimumCodeSize(forColorCount colorCount: Int) -> Int {
        var bits = 2
        while (1 << bits) < colorCount { bits += 1 }
        return bits
    }

    /// Compresses `indices` and appends the GIF image data (minimum code size
    /// byte, data sub-blocks and the zero-length terminator) to `output`.
    public func encode(_ indices: UnsafeBufferPointer<UInt8>, minCodeSize: Int, into output: inout [UInt8]) {
        precondition((2...8).contains(minCodeSize), "GIF LZW minimum code size must be 2...8")
        output.append(UInt8(minCodeSize))

        let clearCode = 1 << minCodeSize
        let endCode = clearCode + 1
        let initialBits = minCodeSize + 1

        var codeSize = initialBits
        var maxCode = (1 << codeSize) - 1
        var nextCode = clearCode + 2
        var clearPending = false

        bitBuffer = 0
        bitCount = 0
        blockLength = 0

        func emit(_ code: Int, into output: inout [UInt8]) {
            bitBuffer |= UInt64(code) << UInt64(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                appendByte(UInt8(truncatingIfNeeded: bitBuffer), into: &output)
                bitBuffer >>= 8
                bitCount -= 8
            }
            if nextCode > maxCode || clearPending {
                if clearPending {
                    codeSize = initialBits
                    maxCode = (1 << codeSize) - 1
                    clearPending = false
                } else {
                    codeSize += 1
                    maxCode = codeSize == LZWEncoder.maxBits ? LZWEncoder.maxCodes : (1 << codeSize) - 1
                }
            }
        }

        resetTable()
        emit(clearCode, into: &output)

        if indices.isEmpty {
            emit(endCode, into: &output)
            finish(into: &output)
            return
        }

        codes.withUnsafeMutableBufferPointer { codes in
            stamps.withUnsafeMutableBufferPointer { stamps in
                var prefix = Int(indices[0])
                var i = 1
                let count = indices.count
                while i < count {
                    let suffix = Int(indices[i])
                    i += 1
                    let key = (prefix << 8) | suffix
                    if stamps[key] == generation {
                        prefix = Int(codes[key])
                        continue
                    }
                    emit(prefix, into: &output)
                    prefix = suffix
                    if nextCode < LZWEncoder.maxCodes {
                        codes[key] = UInt16(nextCode)
                        stamps[key] = generation
                        nextCode += 1
                    } else {
                        // Table full: start over with a clear code.
                        generation &+= 1
                        if generation == 0 {
                            for j in stamps.indices { stamps[j] = 0 }
                            generation = 1
                        }
                        nextCode = clearCode + 2
                        clearPending = true
                        emit(clearCode, into: &output)
                    }
                }
                emit(prefix, into: &output)
            }
        }
        emit(endCode, into: &output)
        finish(into: &output)
    }

    private func resetTable() {
        generation &+= 1
        if generation == 0 {
            for j in stamps.indices { stamps[j] = 0 }
            generation = 1
        }
    }

    @inline(__always)
    private func appendByte(_ byte: UInt8, into output: inout [UInt8]) {
        block[blockLength] = byte
        blockLength += 1
        if blockLength == 255 { flushBlock(into: &output) }
    }

    private func flushBlock(into output: inout [UInt8]) {
        guard blockLength > 0 else { return }
        output.append(UInt8(blockLength))
        output.append(contentsOf: block[0..<blockLength])
        blockLength = 0
    }

    private func finish(into output: inout [UInt8]) {
        if bitCount > 0 {
            appendByte(UInt8(truncatingIfNeeded: bitBuffer), into: &output)
            bitBuffer = 0
            bitCount = 0
        }
        flushBlock(into: &output)
        output.append(0) // block terminator
    }
}
