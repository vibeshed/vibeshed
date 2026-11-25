import CoreGraphics
import Foundation

/// The ASCII style's other two subjects: the Mandelbrot set, the favorite of 80s BASIC
/// listings, and aalib's `aafire`, the flames every text-mode demo showed off.
extension WallpaperCanvas {
    /// The Mandelbrot set shaded by escape time, the set itself dotted so it glows at the rim.
    mutating func mandelbrotFigure(grid: ASCIIGrid) -> ASCIIFigure {
        let view = ASCIIMandelbrot(real: -0.62 + rng.between(-0.08, 0.08), span: rng.between(3, 3.4) * heightRatio)
        let values = view.render(columns: grid.columns, rows: grid.rows)
        // A palette with few saturated hues (a grayscale one) gives fewer than three.
        let tones = harmony(3)
        let shades = asciiShades(isDark
            ? [muted(tones.cycling(2), 0.55), muted(tones.cycling(1), 0.2), palette.accent,
               palette.accent.mix(palette.brightForeground, 0.7)]
            : [palette.background.mix(tones.cycling(2), 0.5), tones.cycling(1), palette.accent,
               palette.accent.mix(palette.foreground, 0.5)])
        let ramp = Self.asciiRamp.count
        let inside = ASCIIMark(glyph: 0, color: muted(palette.accent, isDark ? 0.35 : 0.3))
        return ASCIIFigure(
            marks: values.map { value in
                guard let value else { return inside }
                // Points that escape within a few steps stay blank, so the set floats in space.
                let level = Int((value - 0.3) / 0.7 * Double(ramp))
                return level > 0 ? ASCIIMark(glyph: min(level, ramp - 1), color: shades[min(level, ramp - 1)]) : nil
            },
            glowCenter: CGPoint(x: width / 2, y: height / 2), glowRadius: unit * 500,
            glowColor: palette.accent, haze: false
        )
    }

    /// Flames rising from the bottom edge, burning harder where the fuel does, under stars.
    mutating func fireFigure(grid: ASCIIGrid) -> ASCIIFigure {
        let offset = rng.between(0, 100)
        let fuel = (0 ..< grid.columns).map { column in
            let value = noise.fractal(Double(column) * 0.05 + offset, offset, octaves: 3)
            return 0.15 + 0.75 * min(max((value - 0.3) / 0.4, 0), 1)
        }
        let fire = ASCIIFire(fuel: fuel, cooling: 1.9 / Double(grid.rows))
        let heat = fire.render(rows: grid.rows, rng: &rng)
        let shades = asciiShades(isDark
            ? [muted(palette.red, 0.5), palette.red, palette.orange, palette.yellow,
               palette.yellow.mix(palette.brightForeground, 0.7)]
            : [palette.background.mix(palette.yellow, 0.6), palette.orange, palette.red,
               palette.red.mix(palette.foreground, 0.5)])
        let ramp = Self.asciiRamp.count
        return ASCIIFigure(
            marks: heat.map { value in
                let level = min(Int(value * 1.4 * Double(ramp)), ramp - 1)
                return level > 0 ? ASCIIMark(glyph: level, color: shades[level]) : nil
            },
            glowCenter: CGPoint(x: width / 2, y: 0), glowRadius: height * 0.8,
            glowColor: isDark ? palette.orange : palette.red, haze: false
        )
    }
}

/// The Mandelbrot set framed on the grid: `span` is the imaginary height the grid shows,
/// centered on the real axis at `real`; a column is half a row's step, since cells are twice
/// as tall as wide.
struct ASCIIMandelbrot {
    let real: Double
    let span: Double

    private static let iterations = 400

    /// Per cell, row-major: nil inside the set, else how close the point came to staying,
    /// in `0...1` (smooth escape time on a log scale).
    func render(columns: Int, rows: Int) -> [Double?] {
        let step = span / Double(rows)
        let limit = log(Double(Self.iterations))
        var values = [Double?](repeating: nil, count: columns * rows)
        for row in 0 ..< rows {
            let ci = -(Double(row) + 0.5 - Double(rows) / 2) * step
            for column in 0 ..< columns {
                let cr = real + (Double(column) + 0.5 - Double(columns) / 2) * step / 2
                var (zr, zi, count) = (0.0, 0.0, 0)
                while count < Self.iterations, zr * zr + zi * zi < 256 {
                    (zr, zi) = (zr * zr - zi * zi + cr, 2 * zr * zi + ci)
                    count += 1
                }
                guard count < Self.iterations else { continue }
                let smooth = Double(count) + 1 - log2(log(zr * zr + zi * zi) / 2)
                values[row * columns + column] = min(max(log(max(smooth, 1)) / limit, 0), 1)
            }
        }
        return values
    }
}

/// aalib's `aafire`: random heat fed in below the bottom row, each cell the average of three
/// below it and one two below, less a little cooling, run until the flames settle.
struct ASCIIFire {
    /// Per column, the chance in `0...1` that its feed cell is lit on a frame.
    let fuel: [Double]
    /// Heat lost per row climbed.
    let cooling: Double

    /// Heat per cell in `0...1`, row-major with row 0 at the top.
    func render(rows: Int, rng: inout SeededGenerator) -> [Double] {
        let columns = fuel.count
        var heat = [Double](repeating: 0, count: columns * (rows + 2))
        for _ in 0 ..< rows * 2 {
            for row in rows ..< rows + 2 {
                for column in 0 ..< columns {
                    heat[row * columns + column] = rng.unit() < fuel[column] ? 1 : 0
                }
            }
            for row in 0 ..< rows {
                let below = (row + 1) * columns, twoBelow = (row + 2) * columns
                for column in 0 ..< columns {
                    let sum = heat[below + max(column - 1, 0)] + heat[below + column]
                        + heat[below + min(column + 1, columns - 1)] + heat[twoBelow + column]
                    heat[row * columns + column] = max(sum / 4 - cooling, 0)
                }
            }
        }
        return Array(heat.prefix(columns * rows))
    }
}
