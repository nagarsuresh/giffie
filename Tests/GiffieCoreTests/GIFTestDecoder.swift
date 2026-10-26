import Foundation

/// Minimal, independent GIF decoder used to verify encoder output.
/// Composites frames onto a canvas (honouring transparency and disposal 1)
/// and returns every fully composited frame as `0x00RRGGBB` pixels.
struct DecodedGIF {
    struct Frame {
        var pixels: [UInt32]
        var delay: Int // centiseconds
        var rect: (x: Int, y: Int, w: Int, h: Int)
        var transparentIndex: Int?
        var colorTableSize: Int
    }

    var width: Int
    var height: Int
    var loopCount: Int?
    var frames: [Frame]

    var totalDelay: Int { frames.reduce(0) { $0 + $1.delay } }
}

enum GIFDecodeError: Error {
    case badHeader, truncated, badBlock(UInt8), badCode
}

func decodeGIF(_ data: Data) throws -> DecodedGIF {
    let bytes = [UInt8](data)
    var pos = 0

    func u8() throws -> Int {
        guard pos < bytes.count else { throw GIFDecodeError.truncated }
        defer { pos += 1 }
        return Int(bytes[pos])
    }
    func u16() throws -> Int { let lo = try u8(); let hi = try u8(); return lo | (hi << 8) }
    func subBlocks() throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let n = try u8()
            if n == 0 { return out }
            guard pos + n <= bytes.count else { throw GIFDecodeError.truncated }
            out.append(contentsOf: bytes[pos..<(pos + n)])
            pos += n
        }
    }
    func colorTable(_ count: Int) throws -> [UInt32] {
        var table: [UInt32] = []
        for _ in 0..<count {
            let r = try u8(), g = try u8(), b = try u8()
            table.append(UInt32(r << 16 | g << 8 | b))
        }
        return table
    }

    guard bytes.count >= 13, String(bytes: bytes[0..<6], encoding: .ascii) == "GIF89a" else {
        throw GIFDecodeError.badHeader
    }
    pos = 6
    let width = try u16(), height = try u16()
    let packed = try u8()
    _ = try u8(); _ = try u8()
    var globalTable: [UInt32]? = nil
    if packed & 0x80 != 0 { globalTable = try colorTable(1 << ((packed & 7) + 1)) }

    var canvas = [UInt32](repeating: 0, count: width * height)
    var result = DecodedGIF(width: width, height: height, loopCount: nil, frames: [])
    var delay = 0
    var transparent: Int? = nil

    loop: while true {
        let introducer = try u8()
        switch introducer {
        case 0x21:
            let label = try u8()
            if label == 0xF9 {
                let block = try subBlocks()
                guard block.count == 4 else { throw GIFDecodeError.badBlock(UInt8(label)) }
                delay = Int(block[1]) | Int(block[2]) << 8
                transparent = block[0] & 1 != 0 ? Int(block[3]) : nil
            } else if label == 0xFF {
                let block = try subBlocks()
                if block.count >= 14, String(bytes: block[0..<11], encoding: .ascii) == "NETSCAPE2.0" {
                    result.loopCount = Int(block[12]) | Int(block[13]) << 8
                }
            } else {
                _ = try subBlocks()
            }
        case 0x2C:
            let x = try u16(), y = try u16(), w = try u16(), h = try u16()
            let flags = try u8()
            var table = globalTable ?? []
            var tableSize = table.count
            if flags & 0x80 != 0 {
                tableSize = 1 << ((flags & 7) + 1)
                table = try colorTable(tableSize)
            }
            let minCodeSize = try u8()
            let data = try subBlocks()
            let indices = try lzwDecode(data, minCodeSize: minCodeSize, pixelCount: w * h)
            for row in 0..<h {
                for col in 0..<w {
                    let index = Int(indices[row * w + col])
                    if index == transparent { continue }
                    let cx = x + col, cy = y + row
                    guard cx < width, cy < height else { continue }
                    canvas[cy * width + cx] = table[index]
                }
            }
            result.frames.append(.init(pixels: canvas, delay: delay, rect: (x, y, w, h),
                                       transparentIndex: transparent, colorTableSize: tableSize))
            delay = 0
            transparent = nil
        case 0x3B:
            break loop
        default:
            throw GIFDecodeError.badBlock(UInt8(introducer))
        }
    }
    return result
}

func lzwDecode(_ data: [UInt8], minCodeSize: Int, pixelCount: Int) throws -> [UInt8] {
    let clearCode = 1 << minCodeSize
    let endCode = clearCode + 1
    var codeSize = minCodeSize + 1
    var dictionary: [[UInt8]] = []
    func reset() {
        dictionary = (0..<clearCode).map { [UInt8($0)] }
        dictionary.append([]) // clear
        dictionary.append([]) // end
        codeSize = minCodeSize + 1
    }
    reset()

    var bitPos = 0
    func read() -> Int? {
        guard bitPos + codeSize <= data.count * 8 else { return nil }
        var value = 0
        for i in 0..<codeSize {
            let bit = (Int(data[(bitPos + i) / 8]) >> ((bitPos + i) % 8)) & 1
            value |= bit << i
        }
        bitPos += codeSize
        return value
    }

    var output: [UInt8] = []
    output.reserveCapacity(pixelCount)
    var previous: [UInt8]? = nil
    while let code = read() {
        if code == clearCode {
            reset()
            previous = nil
            continue
        }
        if code == endCode { break }
        let entry: [UInt8]
        if code < dictionary.count {
            entry = dictionary[code]
        } else if code == dictionary.count, let previous = previous {
            entry = previous + [previous[0]]
        } else {
            throw GIFDecodeError.badCode
        }
        output.append(contentsOf: entry)
        if let previous = previous, dictionary.count < 4096 {
            dictionary.append(previous + [entry[0]])
        }
        previous = entry
        if dictionary.count == (1 << codeSize) && codeSize < 12 {
            codeSize += 1
        }
    }
    guard output.count >= pixelCount else { throw GIFDecodeError.truncated }
    return Array(output.prefix(pixelCount))
}
