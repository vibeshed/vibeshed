import CoreGraphics
import Foundation

extension WallpaperCanvas {
    // MARK: - Topographic

    /// Contour lines of a fractal noise landscape (marching squares), every fourth
    /// line picked out in the accent.
    mutating func paintTopographic() {
        fill(palette.background)
        glow(palette.accent, at: point(rng.between(0.6, 0.9), rng.between(0.6, 0.9)),
             radius: max(width, height) * 0.7, alpha: isDark ? 0.12 : 0.08)

        let columns = Int((220 * spread.width).rounded())
        let rows = max(2, Int(Double(columns) * Double(height / width)))
        let offset = rng.between(0, 100), across = 3.4 * spread.width
        var field = [[Double]](repeating: [Double](repeating: 0, count: columns + 1), count: rows + 1)
        for row in 0 ... rows {
            for column in 0 ... columns {
                let x = Double(column) / Double(columns) * across + offset
                let y = Double(row) / Double(rows) * across * Double(height / width) + offset
                field[row][column] = noise.fractal(x, y, octaves: 4)
            }
        }
        let cell = CGSize(width: width / CGFloat(columns), height: height / CGFloat(rows))
        let levels = 16
        context.setLineCap(.round)
        for level in 1 ..< levels {
            let threshold = 0.2 + 0.6 * Double(level) / Double(levels)
            let isMajor = level % 4 == 0
            let color = isMajor ? palette.accent : palette.muted
            context.setStrokeColor(color.cgColor.copy(alpha: isMajor ? 0.75 : 0.45) ?? color.cgColor)
            context.setLineWidth(max(unit * (isMajor ? 2.2 : 1.3), isMajor ? 1.5 : 1))
            strokeContour(field, threshold: threshold, cell: cell)
        }
    }

    private func strokeContour(_ field: [[Double]], threshold: Double, cell: CGSize) {
        for row in 0 ..< field.count - 1 {
            for column in 0 ..< field[row].count - 1 {
                // Corners: south-west, south-east, north-east, north-west.
                let sw = field[row][column], se = field[row][column + 1]
                let ne = field[row + 1][column + 1], nw = field[row + 1][column]
                let index = (sw > threshold ? 1 : 0) | (se > threshold ? 2 : 0)
                    | (ne > threshold ? 4 : 0) | (nw > threshold ? 8 : 0)
                guard index != 0, index != 15 else { continue }

                func lerp(_ from: Double, _ to: Double) -> CGFloat {
                    CGFloat((threshold - from) / (to - from))
                }
                let x0 = CGFloat(column) * cell.width, y0 = CGFloat(row) * cell.height
                let edges = CellEdges(
                    bottom: CGPoint(x: x0 + lerp(sw, se) * cell.width, y: y0),
                    right: CGPoint(x: x0 + cell.width, y: y0 + lerp(se, ne) * cell.height),
                    top: CGPoint(x: x0 + lerp(nw, ne) * cell.width, y: y0 + cell.height),
                    left: CGPoint(x: x0, y: y0 + lerp(sw, nw) * cell.height)
                )
                for (start, end) in edges.segments(forCase: index) {
                    context.move(to: start)
                    context.addLine(to: end)
                }
            }
        }
        context.strokePath()
    }

    // MARK: - Retro sunset

    /// A striped sun sinking behind a perspective grid, synthwave-style.
    mutating func paintSunset() {
        let horizonY = height * 0.36
        let skyLow = (isDark ? palette.magenta : palette.orange).mix(base, isDark ? 0.55 : 0.5)
        let skyTop = base
        linear([skyTop, skyLow], from: CGPoint(x: 0, y: height), to: CGPoint(x: 0, y: horizonY))

        if isDark {
            for _ in 0 ..< 90 {
                let star = CGPoint(x: width * rng.unit(), y: horizonY + (height - horizonY) * rng.between(0.25, 1))
                let twinkle = palette.foreground.cgColor.copy(alpha: rng.between(0.15, 0.6))
                context.setFillColor(twinkle ?? palette.foreground.cgColor)
                disc(at: star, radius: unit * rng.between(0.6, 1.6))
            }
        }

        let radius = unit * 240
        let sun = CGPoint(x: width * rng.between(0.4, 0.6), y: horizonY + radius * 0.35)
        glow(palette.magenta.mix(palette.orange, 0.5), at: sun, radius: radius * 2.4, alpha: isDark ? 0.35 : 0.2)
        context.saveGState()
        context.addEllipse(in: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        linear([palette.yellow, palette.orange, palette.magenta],
               from: CGPoint(x: 0, y: sun.y + radius), to: CGPoint(x: 0, y: sun.y - radius))
        // Horizontal cut-outs, thickening toward the bottom, painted in the sky behind.
        for band in 0 ..< 7 {
            let y = sun.y - radius * CGFloat(0.05 + 0.13 * Double(band))
            let thickness = unit * CGFloat(3 + 3.2 * Double(band))
            let fraction = Double((y - horizonY) / (height - horizonY))
            context.setFillColor(skyLow.mix(skyTop, fraction).cgColor)
            context.fill(CGRect(x: sun.x - radius, y: y - thickness / 2, width: radius * 2, height: thickness))
        }
        context.restoreGState()

        context.setFillColor((isDark ? palette.darkerBackground : palette.darkBackground).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: horizonY))
        let gridColor = isDark ? palette.cyan : palette.magenta
        context.setStrokeColor(gridColor.cgColor.copy(alpha: 0.55) ?? gridColor.cgColor)
        context.setLineWidth(unit * 1.6)
        for line in 1 ... 14 {
            let y = horizonY * CGFloat(pow(Double(line) / 14, 2.1))
            context.move(to: CGPoint(x: 0, y: horizonY - y))
            context.addLine(to: CGPoint(x: width, y: horizonY - y))
        }
        let vanishing = CGPoint(x: width / 2, y: horizonY)
        for line in -16 ... 16 {
            context.move(to: vanishing)
            context.addLine(to: CGPoint(x: width / 2 + CGFloat(line) * width * 0.09, y: 0))
        }
        context.strokePath()
        // Fade the grid into the horizon haze.
        let haze = (isDark ? palette.darkerBackground : palette.darkBackground)
        linearBand([haze, haze], alphas: [1, 0], from: horizonY, to: horizonY * 0.55)
    }

    private func linearBand(_ colors: [ThemeColor], alphas: [Double], from top: CGFloat, to bottom: CGFloat) {
        let stops = zip(colors, alphas).compactMap { $0.cgColor.copy(alpha: $1) }
        guard let gradient = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: nil) else { return }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: bottom, width: width, height: top - bottom))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
        context.restoreGState()
    }

    // MARK: - Retro arcs

    /// Concentric seventies bands in the palette's hues, fanning out from a corner.
    mutating func paintArcs() {
        fill(palette.background)
        let center = point(rng.between(0.05, 0.3), rng.between(-0.12, 0.05))
        let bands = [palette.red, palette.orange, palette.yellow, palette.green, palette.cyan, palette.blue]
            .map { muted($0, isDark ? 0.3 : 0.25) }
        let outer = max(width, height) * CGFloat(rng.between(0.85, 1.0))
        let bandWidth = outer * 0.085
        for (index, color) in bands.enumerated() {
            let radius = outer - bandWidth * CGFloat(index)
            context.setFillColor(color.cgColor)
            disc(at: center, radius: radius)
        }
        let inner = outer - bandWidth * CGFloat(bands.count)
        context.setFillColor(palette.background.cgColor)
        disc(at: center, radius: inner)
    }
}

/// Where a contour crosses each side of a marching-squares cell.
private struct CellEdges {
    let bottom, right, top, left: CGPoint

    /// Line segments for a corner-inside bit pattern (1 SW, 2 SE, 4 NE, 8 NW).
    func segments(forCase index: Int) -> [(CGPoint, CGPoint)] {
        switch index {
        case 1, 14: [(left, bottom)]
        case 2, 13: [(bottom, right)]
        case 3, 12: [(left, right)]
        case 4, 11: [(right, top)]
        case 6, 9: [(bottom, top)]
        case 7, 8: [(left, top)]
        case 5: [(left, top), (bottom, right)]
        default: [(left, bottom), (right, top)] // 10
        }
    }
}
