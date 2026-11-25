import CoreGraphics
import Foundation

/// Shared machinery for the styles that compute a lot: per-pixel fields and particle
/// simulations. Work runs on four fixed lanes, as `AttractorDensity` does, so a render never
/// depends on the machine and a seed always paints the same picture. Hot loops read and
/// write raw pointers, which debug builds (what `make install` ships) still compile to
/// plain loads and stores.
enum RenderLanes {
    /// Fixed, so the split (and any per-lane randomness) is the same on every Mac.
    static let count = 4

    /// Runs `body` once per lane, concurrently, with that lane's share of `0 ..< total`.
    static func split(_ total: Int, _ body: @Sendable (_ lane: Int, _ range: Range<Int>) -> Void) {
        DispatchQueue.concurrentPerform(iterations: count) { lane in
            body(lane, lane * total / count ..< (lane + 1) * total / count)
        }
    }
}

/// Zeroed memory the lanes share, for plain numeric elements. The compiler can't check
/// it: lanes must only read it, or write disjoint slices, which is what makes sending it
/// safe. Freed explicitly with `deallocate()`.
struct LaneBuffer<Element>: @unchecked Sendable {
    let base: UnsafeMutablePointer<Element>
    let count: Int

    init(zeroed count: Int) {
        self.count = count
        base = .allocate(capacity: max(count, 1))
        memset(base, 0, max(count, 1) * MemoryLayout<Element>.stride)
    }

    /// Wraps memory someone else owns and frees.
    init(wrapping base: UnsafeMutablePointer<Element>, count: Int) {
        self.base = base
        self.count = count
    }

    func deallocate() {
        base.deallocate()
    }
}

/// A color as 0–255 channels, for blending pixel by pixel.
struct PixelTone: Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ color: ThemeColor) {
        red = color.red * 255
        green = color.green * 255
        blue = color.blue * 255
    }

    /// Linear blend toward `other`; `amount` must already be in `0...1`.
    func mixed(_ other: PixelTone, _ amount: Double) -> PixelTone {
        var blend = self
        blend.red += (other.red - red) * amount
        blend.green += (other.green - green) * amount
        blend.blue += (other.blue - blue) * amount
        return blend
    }

    /// Stores the tone as one RGBX pixel.
    func write(to pixel: UnsafeMutablePointer<UInt8>) {
        pixel[0] = UInt8(red + 0.5)
        pixel[1] = UInt8(green + 0.5)
        pixel[2] = UInt8(blue + 0.5)
        pixel[3] = 255
    }
}

/// SplitMix64's output mixing: a well-scrambled 64 bits from any input, such as a counter or
/// a hash of a step and an index — randomness lanes can draw in any order.
func scrambled(_ value: UInt64) -> UInt64 {
    var mixed = value
    mixed = (mixed ^ (mixed &>> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed &>> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed &>> 31)
}

/// `value` clamped to `0...1`, without the generic `min`/`max` that debug builds call
/// rather than inline — it shows in loops that run millions of times.
func clampUnit(_ value: Double) -> Double {
    value < 0 ? 0 : value > 1 ? 1 : value
}

extension WallpaperCanvas {
    /// Paints the canvas pixel by pixel at full device resolution: `shade` fills one row of
    /// `Int(width)` RGBX pixels (row 0 at the top) at the pointer it's given. Rows are split
    /// across the lanes, each writing only its own. Call it before entering unit space.
    func paintRows(_ shade: @Sendable (_ row: Int, _ pixels: UnsafeMutablePointer<UInt8>) -> Void) {
        let columns = Int(width), rows = Int(height), stride = columns * 4
        guard let memory = malloc(stride * rows) else { return fill(base) }
        let pixels = LaneBuffer(
            wrapping: memory.bindMemory(to: UInt8.self, capacity: stride * rows), count: stride * rows
        )
        RenderLanes.split(rows) { _, band in
            for row in band {
                shade(row, pixels.base + row * stride)
            }
        }
        // The provider takes the memory over, so a full-resolution frame isn't copied.
        guard let provider = CGDataProvider(
            dataInfo: nil, data: memory, size: stride * rows,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
        ) else {
            free(memory)
            return fill(base)
        }
        guard let image = CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return fill(base) }
        context.draw(image, in: rect)
    }

    /// Draws `image` (row 0 at the top) into `frame` in unit space, where y points down and
    /// a plain draw would turn it upside down.
    func drawUpright(_ image: CGImage, in frame: CGRect) {
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }
}

/// A smooth field sampled on a grid and read back bilinearly. `ValueNoise` costs about a
/// microsecond a sample in debug builds, so styles that read a field hundreds of thousands
/// of times sample it once here, on the lanes, and interpolate.
final class SampledField: @unchecked Sendable {
    private let values: LaneBuffer<Double>
    private let origin: CGPoint
    private let spacing: Double
    private let columns: Int
    private let rows: Int

    /// Samples `sample` every `spacing` over `area`, one sample past each edge.
    init(over area: CGRect, spacing: Double, sample: @Sendable (_ x: Double, _ y: Double) -> Double) {
        let columns = Int((area.width / spacing).rounded(.up)) + 2, rows = Int((area.height / spacing).rounded(.up)) + 2
        let values = LaneBuffer<Double>(zeroed: columns * rows), origin = area.origin
        RenderLanes.split(rows) { _, band in
            for row in band {
                for column in 0 ..< columns {
                    values.base[row * columns + column] = sample(
                        origin.x + Double(column) * spacing, origin.y + Double(row) * spacing
                    )
                }
            }
        }
        (self.values, self.origin, self.spacing, self.columns, self.rows) = (values, origin, spacing, columns, rows)
    }

    deinit {
        values.deallocate()
    }

    /// The field at (x, y), held at the edge outside the sampled area.
    func value(_ x: Double, _ y: Double) -> Double {
        let gridX = clampUnit((x - origin.x) / spacing / Double(columns - 1)) * Double(columns - 1)
        let gridY = clampUnit((y - origin.y) / spacing / Double(rows - 1)) * Double(rows - 1)
        let column = Int(gridX) < columns - 1 ? Int(gridX) : columns - 2
        let row = Int(gridY) < rows - 1 ? Int(gridY) : rows - 2
        let across = gridX - Double(column), down = gridY - Double(row)
        let corner = values.base + row * columns + column
        let top = corner[0] + (corner[1] - corner[0]) * across
        let bottom = corner[columns] + (corner[columns + 1] - corner[columns]) * across
        return top + (bottom - top) * down
    }
}
