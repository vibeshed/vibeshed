import CoreGraphics
import Foundation

/// Line art in the pen-plotter tradition. These styles draw in unit space
/// (`WallpaperCanvas+Units`).
extension WallpaperCanvas {
    // MARK: - Pulsar

    /// Stacked line plots that rise into peaks near the middle, each hiding the lines behind
    /// it — after Peter Saville's Unknown Pleasures cover (1979), a plot of pulsar CP 1919.
    mutating func paintPulsar() {
        enterUnitSpace()
        fill(base)
        let lines = 62, steps = 170, top = 220 + (unitHeight - 1000) / 2
        let span = min(unitWidth * rng.between(0.34, 0.42), 760), left = (unitWidth - span) / 2
        let gap: CGFloat = 630 / CGFloat(lines - 1)
        context.setLineJoin(.round)
        context.setLineWidth(hairline(1.6))
        context.setStrokeColor(palette.foreground.cgColor)
        context.setFillColor(base.cgColor)
        for line in 0 ..< lines {
            let baseline = top + CGFloat(line) * gap
            let points = pulse(line: line, gap: gap, steps: steps).enumerated().map { step, lift in
                CGPoint(x: left + span * CGFloat(step) / CGFloat(steps), y: baseline - lift)
            }
            // Paint out what's behind the line first, so nearer lines hide farther ones.
            let ground = CGMutablePath()
            ground.addLines(between: points + [
                CGPoint(x: left + span, y: baseline + gap * 1.5), CGPoint(x: left, y: baseline + gap * 1.5),
            ])
            ground.closeSubpath()
            context.addPath(ground)
            context.fillPath()
            context.addLines(between: points)
            context.strokePath()
        }
    }

    /// Heights of one pulsar line above its baseline, sampled `steps + 1` times across:
    /// a few gaussian peaks under a central envelope, plus noise.
    private mutating func pulse(line: Int, gap: CGFloat, steps: Int) -> [CGFloat] {
        let bumps = (0 ..< 2 + rng.int(below: 4)).map { _ in
            (center: rng.between(0.37, 0.63), spread: rng.between(0.012, 0.045), height: rng.between(0.25, 1))
        }
        return (0 ... steps).map { step in
            let along = Double(step) / Double(steps)
            let envelope = exp(-pow((along - 0.5) / 0.17, 2))
            let peak = bumps.reduce(0) { $0 + $1.height * exp(-pow((along - $1.center) / $1.spread, 2)) }
            let jitter = noise.fractal(along * 24 + Double(line) * 3.7, Double(line) * 5.3, octaves: 3) - 0.5
            let lift = (min(peak, 1.6) * envelope * 5.2 + jitter * (0.6 + 2.4 * envelope)) * Double(gap)
            return CGFloat(max(lift, -0.35 * Double(gap)))
        }
    }

    // MARK: - Guilloché

    /// Hairline rosettes like the engine-turned engraving on banknotes: bands of closed
    /// curves r(θ) = R + A·sin(kθ + φ) + 0.3A·sin((2k + 1)θ − 2φ), with the phases φ spread
    /// around the circle so the curves braid into lace.
    mutating func paintGuilloche() {
        enterUnitSpace()
        linear([surface, base], from: .zero, to: CGPoint(x: 0, y: unitHeight))
        let center = CGPoint(x: unitWidth * rng.between(0.52, 0.66), y: unitHeight * rng.between(0.45, 0.55))
        let bands = [
            GuillocheBand(radius: 130, depth: 24, lobes: 8 + rng.int(below: 4), lines: 30),
            GuillocheBand(radius: 270, depth: 40, lobes: 13 + rng.int(below: 6), lines: 44),
            GuillocheBand(radius: 420, depth: 34, lobes: 21 + rng.int(below: 8), lines: 52),
            GuillocheBand(radius: 590, depth: 52, lobes: 16 + rng.int(below: 8), lines: 60),
        ]
        let hues = harmony(3)
        context.setLineWidth(hairline(0.6, minimum: 0.8))
        for (index, band) in bands.enumerated() {
            context.setStrokeColor(muted(hues.cycling(index), isDark ? 0.12 : 0.08).cgColor(alpha: 0.7))
            for line in 0 ..< band.lines {
                context.addPath(band.curve(around: center, phase: Double(line) / Double(band.lines) * 2 * .pi))
                context.strokePath()
            }
        }
    }

    // MARK: - Sashiko

    /// Hitomezashi stitching: along every grid line, running stitches start on or off the
    /// first cell by a random bit. The stitches close off shapes that always two-color, and
    /// every other shape is tinted.
    mutating func paintSashiko() {
        enterUnitSpace()
        let cell: CGFloat = 30
        let columns = Int((unitWidth / cell).rounded(.up)) + 1, rows = Int((unitHeight / cell).rounded(.up)) + 1
        let pattern = Hitomezashi(
            rowBits: (0 ... rows).map { _ in rng.int(below: 2) == 1 },
            columnBits: (0 ... columns).map { _ in rng.int(below: 2) == 1 }
        )
        fill(base)
        context.setFillColor(base.mix(palette.accent, isDark ? 0.13 : 0.09).cgColor)
        let tinted = pattern.regions(columns: columns, rows: rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns where tinted[row * columns + column] {
                let square = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                context.fill(square.insetBy(dx: -0.4, dy: -0.4))
            }
        }
        let inset = cell * 0.15, stitches = CGMutablePath()
        for row in 0 ... rows {
            for column in 0 ..< columns where pattern.across(column, row) {
                let y = CGFloat(row) * cell
                stitches.move(to: CGPoint(x: CGFloat(column) * cell + inset, y: y))
                stitches.addLine(to: CGPoint(x: CGFloat(column + 1) * cell - inset, y: y))
            }
        }
        for column in 0 ... columns {
            for row in 0 ..< rows where pattern.down(column, row) {
                let x = CGFloat(column) * cell
                stitches.move(to: CGPoint(x: x, y: CGFloat(row) * cell + inset))
                stitches.addLine(to: CGPoint(x: x, y: CGFloat(row + 1) * cell - inset))
            }
        }
        context.addPath(stitches)
        context.setLineCap(.round)
        context.setLineWidth(2.6)
        context.setStrokeColor(muted(palette.foreground, isDark ? 0.15 : 0.2).cgColor)
        context.strokePath()
    }
}

/// One braided band of a guilloché rosette.
private struct GuillocheBand {
    let radius: Double
    let depth: Double
    let lobes: Int
    let lines: Int

    func curve(around center: CGPoint, phase: Double) -> CGPath {
        let lace = Double(lobes * 2 + 1)
        let points = (0 ..< 1000).map { step in
            let angle = Double(step) / 1000 * 2 * .pi
            let reach = radius + depth * sin(Double(lobes) * angle + phase)
                + depth * 0.3 * sin(lace * angle - 2 * phase)
            return CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle))
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}

/// A hitomezashi stitch pattern: horizontal grid line `row` is stitched on alternate cells
/// starting on or off the first by `rowBits[row]`, vertical lines likewise by `columnBits`.
struct Hitomezashi {
    let rowBits: [Bool]
    let columnBits: [Bool]

    /// Whether horizontal line `row` is stitched between columns `column` and `column + 1`.
    func across(_ column: Int, _ row: Int) -> Bool {
        (column + (rowBits[row] ? 1 : 0)).isMultiple(of: 2)
    }

    /// Whether vertical line `column` is stitched between rows `row` and `row + 1`.
    func down(_ column: Int, _ row: Int) -> Bool {
        (row + (columnBits[column] ? 1 : 0)).isMultiple(of: 2)
    }

    /// A two-coloring of the cells, row-major: neighbours differ exactly where a stitch
    /// separates them. Every grid point has one stitch on each of its lines, so the
    /// coloring settled by walking down the first column and along each row is consistent.
    func regions(columns: Int, rows: Int) -> [Bool] {
        var colors = [Bool](repeating: false, count: columns * rows)
        var first = false
        for row in 0 ..< rows {
            if row > 0, across(0, row) { first.toggle() }
            var color = first
            for column in 0 ..< columns {
                if column > 0, down(column, row) { color.toggle() }
                colors[row * columns + column] = color
            }
        }
        return colors
    }
}
