import Foundation

/// Builds a palette of at most `maxColors` entries for a set of pixels and maps
/// pixels to palette indices.
///
/// Colors are `0x00RRGGBB` values. When the input contains no more distinct
/// colors than allowed (very common for UI recordings) the palette is exact
/// and the frame is lossless. Otherwise a median-cut over an RGB555 histogram
/// is used, with palette entries averaged at full 8-bit precision.
///
/// Instances keep their scratch tables between calls; reuse one per encoder.
public final class ColorQuantizer {
    public private(set) var palette: [UInt32] = []
    public private(set) var isExact = false

    // Exact-color hash table (open addressing). 0xFFFFFFFF marks an empty slot,
    // which can never collide with a real color because colors are 24-bit.
    private static let exactTableSize = 1024
    private static let emptySlot: UInt32 = 0xFFFF_FFFF
    private var exactKeys = [UInt32](repeating: ColorQuantizer.emptySlot, count: ColorQuantizer.exactTableSize)
    private var exactValues = [UInt8](repeating: 0, count: ColorQuantizer.exactTableSize)

    // RGB555 histogram for median cut.
    private var histCount = [Int](repeating: 0, count: 1 << 15)
    private var histR = [Int](repeating: 0, count: 1 << 15)
    private var histG = [Int](repeating: 0, count: 1 << 15)
    private var histB = [Int](repeating: 0, count: 1 << 15)
    private var usedBins: [Int] = []

    // Nearest-color cache keyed by RGB666; 0xFFFF = not computed yet.
    private var nearestCache = [UInt16](repeating: 0xFFFF, count: 1 << 18)

    public init() {}

    /// Computes the palette for `pixels`. Call `index(of:)` afterwards to map colors.
    public func buildPalette(_ pixels: UnsafeBufferPointer<UInt32>, maxColors: Int) {
        precondition((2...256).contains(maxColors))
        if buildExactPalette(pixels, maxColors: maxColors) {
            isExact = true
            return
        }
        isExact = false
        buildMedianCutPalette(pixels, maxColors: maxColors)
        for i in nearestCache.indices { nearestCache[i] = 0xFFFF }
    }

    /// Palette index for `color` (`0x00RRGGBB`). Only valid after `buildPalette`.
    @inline(__always)
    public func index(of color: UInt32) -> UInt8 {
        if isExact {
            var slot = ColorQuantizer.hash(color)
            while true {
                let key = exactKeys[slot]
                if key == color { return exactValues[slot] }
                if key == ColorQuantizer.emptySlot { return nearestIndex(color) } // not in the frame's set
                slot = (slot + 1) & (ColorQuantizer.exactTableSize - 1)
            }
        }
        let r = Int((color >> 16) & 0xFF), g = Int((color >> 8) & 0xFF), b = Int(color & 0xFF)
        let key = ((r >> 2) << 12) | ((g >> 2) << 6) | (b >> 2)
        let cached = nearestCache[key]
        if cached != 0xFFFF { return UInt8(cached) }
        let index = nearestIndex(color)
        nearestCache[key] = UInt16(index)
        return index
    }

    // MARK: - Exact palette

    @inline(__always)
    private static func hash(_ color: UInt32) -> Int {
        Int((color &* 2_654_435_761) >> 22) & (exactTableSize - 1)
    }

    private func buildExactPalette(_ pixels: UnsafeBufferPointer<UInt32>, maxColors: Int) -> Bool {
        for i in exactKeys.indices { exactKeys[i] = ColorQuantizer.emptySlot }
        var colors: [UInt32] = []
        colors.reserveCapacity(maxColors)
        var last: UInt32 = ColorQuantizer.emptySlot
        let tableMask = ColorQuantizer.exactTableSize - 1
        for color in pixels {
            if color == last { continue }
            last = color
            var slot = ColorQuantizer.hash(color)
            while true {
                let key = exactKeys[slot]
                if key == color { break }
                if key == ColorQuantizer.emptySlot {
                    if colors.count == maxColors { return false }
                    exactKeys[slot] = color
                    exactValues[slot] = UInt8(colors.count)
                    colors.append(color)
                    break
                }
                slot = (slot + 1) & tableMask
            }
        }
        if colors.isEmpty { colors.append(0) }
        palette = colors
        return true
    }

    // MARK: - Median cut

    private struct Box {
        var range: Range<Int>
        var count: Int
        var score: Int
        var axis: Int
    }

    private func buildMedianCutPalette(_ pixels: UnsafeBufferPointer<UInt32>, maxColors: Int) {
        for bin in usedBins {
            histCount[bin] = 0; histR[bin] = 0; histG[bin] = 0; histB[bin] = 0
        }
        usedBins.removeAll(keepingCapacity: true)

        for color in pixels {
            let r = Int((color >> 16) & 0xFF), g = Int((color >> 8) & 0xFF), b = Int(color & 0xFF)
            let bin = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            if histCount[bin] == 0 { usedBins.append(bin) }
            histCount[bin] += 1
            histR[bin] += r
            histG[bin] += g
            histB[bin] += b
        }

        var bins = usedBins
        var boxes = [makeBox(bins, 0..<bins.count)]

        while boxes.count < maxColors {
            // Split the box with the highest population * extent score.
            var best = -1
            var bestScore = 0
            for (i, box) in boxes.enumerated() where box.range.count > 1 && box.score > bestScore {
                best = i
                bestScore = box.score
            }
            if best < 0 { break }

            let box = boxes[best]
            let axis = box.axis
            let lower = box.range.lowerBound
            let upper = box.range.upperBound
            bins[lower..<upper].sort { ColorQuantizer.component($0, axis) < ColorQuantizer.component($1, axis) }

            // Weighted median along the chosen axis.
            let half = box.count / 2
            var running = 0
            var split = upper - 1
            for i in lower..<(upper - 1) {
                running += histCount[bins[i]]
                if running >= half {
                    split = i + 1
                    break
                }
            }
            split = min(max(split, lower + 1), upper - 1)

            boxes[best] = makeBox(bins, lower..<split)
            boxes.append(makeBox(bins, split..<upper))
        }

        palette = boxes.map { box -> UInt32 in
            var r = 0, g = 0, b = 0, n = 0
            for bin in bins[box.range] {
                r += histR[bin]; g += histG[bin]; b += histB[bin]; n += histCount[bin]
            }
            n = max(n, 1)
            let rr = UInt32((r + n / 2) / n), gg = UInt32((g + n / 2) / n), bb = UInt32((b + n / 2) / n)
            return (rr << 16) | (gg << 8) | bb
        }
    }

    @inline(__always)
    private static func component(_ bin: Int, _ axis: Int) -> Int {
        switch axis {
        case 0: return (bin >> 10) & 31
        case 1: return (bin >> 5) & 31
        default: return bin & 31
        }
    }

    private func makeBox(_ bins: [Int], _ range: Range<Int>) -> Box {
        var minR = 31, minG = 31, minB = 31, maxR = 0, maxG = 0, maxB = 0
        var count = 0
        for bin in bins[range] {
            count += histCount[bin]
            let r = (bin >> 10) & 31, g = (bin >> 5) & 31, b = bin & 31
            minR = min(minR, r); maxR = max(maxR, r)
            minG = min(minG, g); maxG = max(maxG, g)
            minB = min(minB, b); maxB = max(maxB, b)
        }
        // Weight green highest, red next, blue least (rough perceptual weighting).
        let rangeR = (maxR - minR) * 3, rangeG = (maxG - minG) * 4, rangeB = (maxB - minB) * 2
        var axis = 0
        var extent = rangeR
        if rangeG > extent { axis = 1; extent = rangeG }
        if rangeB > extent { axis = 2; extent = rangeB }
        return Box(range: range, count: count, score: count * (extent + 1), axis: axis)
    }

    // MARK: - Nearest color

    private func nearestIndex(_ color: UInt32) -> UInt8 {
        let r = Int((color >> 16) & 0xFF), g = Int((color >> 8) & 0xFF), b = Int(color & 0xFF)
        var best = 0
        var bestDistance = Int.max
        for (i, entry) in palette.enumerated() {
            let dr = r - Int((entry >> 16) & 0xFF)
            let dg = g - Int((entry >> 8) & 0xFF)
            let db = b - Int(entry & 0xFF)
            let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
            if distance < bestDistance {
                bestDistance = distance
                best = i
                if distance == 0 { break }
            }
        }
        return UInt8(best)
    }
}
