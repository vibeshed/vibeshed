import CoreGraphics
import Foundation

/// Classic-OS and classic-computing styles, painted from whatever palette is active.
/// Themes can pin the desktop color with a `desktop` key (the retro themes do). Haiku's
/// Leaves, NeXT's Polyhedra and Windows NT's Pipes live in `WallpaperCanvas+ScreenSavers`.
extension WallpaperCanvas {
    // MARK: - OS/2 Warp

    /// Star streaks rushing out of a vanishing point — the "Warp" in OS/2 Warp.
    mutating func paintWarp() {
        let space = isDark ? palette.darkerBackground : palette.foreground.mix(.black, 0.6)
        fill(space)
        let center = point(rng.between(0.42, 0.58), rng.between(0.42, 0.58))
        let reach = hypot(width, height) * 0.62
        glow(palette.accent.mix(.white, 0.2), at: center, radius: reach * 0.55, alpha: 0.4)
        glow(palette.cyan, at: center, radius: reach * 0.9, alpha: 0.12)
        let tones = harmony(3) + [.white]
        context.setLineCap(.round)
        for _ in 0 ..< 420 {
            let angle = rng.between(0, .pi * 2)
            let start = pow(rng.unit(), 1.5) * reach * 0.95 + unit * 10
            let length = start * rng.between(0.1, 0.45) + unit * 6
            let depth = min(start / reach, 1)
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let color = tones[Int(rng.between(0, Double(tones.count)))].mix(.white, rng.between(0.2, 0.6))
            context.setStrokeColor(color.cgColor.copy(alpha: 0.15 + 0.75 * depth) ?? color.cgColor)
            context.setLineWidth(unit * (0.6 + 3.4 * depth))
            context.move(to: CGPoint(x: center.x + direction.x * start, y: center.y + direction.y * start))
            context.addLine(to: CGPoint(x: center.x + direction.x * (start + length),
                                        y: center.y + direction.y * (start + length)))
            context.strokePath()
        }
    }

    // MARK: - Shared primitives

    func fillRect(_ rect: CGRect, _ color: ThemeColor) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }
}

// MARK: - 10 PRINT and Dither

extension WallpaperCanvas {
    /// `10 PRINT CHR$(205.5+RND(1)); : GOTO 10`, the Commodore 64 one-liner: a maze of
    /// random diagonals (in unit space). The rooms it seals off, regions that never reach
    /// the edge, are found with union-find and most of them are tinted.
    mutating func paintMaze() {
        enterUnitSpace()
        fill(base)
        let cell: CGFloat = 30
        let columns = Int((unitWidth / cell).rounded(.up)), rows = Int((unitHeight / cell).rounded(.up))
        let maze = DiagonalMaze(
            columns: columns, rows: rows, rising: (0 ..< columns * rows).map { _ in rng.int(below: 2) == 1 }
        )
        let tints = harmony(4).map { muted($0, isDark ? 0.5 : 0.45) }
        let shapes = tints.map { _ in CGMutablePath() }
        var tintOfRoom: [Int: Int] = [:] // −1 leaves a room untinted
        for (half, room) in maze.rooms().enumerated() {
            guard let room else { continue }
            let tint = tintOfRoom[room] ?? (rng.unit() < 0.3 ? -1 : rng.int(below: tints.count))
            tintOfRoom[room] = tint
            guard tint >= 0 else { continue }
            shapes[tint].addLines(between: maze.triangle(half, cell: cell))
            shapes[tint].closeSubpath()
        }
        for (shape, tint) in zip(shapes, tints) {
            context.addPath(shape)
            context.setFillColor(tint.cgColor)
            context.fillPath()
        }
        let walls = CGMutablePath()
        for index in 0 ..< columns * rows {
            walls.addLines(between: maze.wall(index, cell: cell))
        }
        context.addPath(walls)
        context.setLineCap(.round)
        context.setLineWidth(3.4)
        context.setStrokeColor(muted(palette.foreground, isDark ? 0.4 : 0.3).cgColor)
        context.strokePath()
    }

    /// The 8×8 Bayer matrix as thresholds in `0 ..< 1`.
    static let bayer: [Double] = [
        0, 48, 12, 60, 3, 51, 15, 63, 32, 16, 44, 28, 35, 19, 47, 31, 8, 56, 4, 52, 11, 59, 7, 55,
        40, 24, 36, 20, 43, 27, 39, 23, 2, 50, 14, 62, 1, 49, 13, 61, 34, 18, 46, 30, 33, 17, 45, 29,
        10, 58, 6, 54, 9, 57, 5, 53, 42, 26, 38, 22, 41, 25, 37, 21,
    ].map { $0 / 64 }

    /// A lit, banded planet in four tones, ordered-dithered with the Bayer matrix into chunky
    /// pixels: the look of 1-bit Macs and 2-bit NeXT screens. Computed as a small bitmap
    /// (a whole number of device pixels per dot) and scaled up without smoothing.
    mutating func paintDither() {
        let dot = max(1, (4.4 * unit).rounded())
        let columns = Int((width / dot).rounded(.up)), rows = Int((height / dot).rounded(.up))
        let radius = Double(min(rows, columns)) * rng.between(0.36, 0.46)
        // Right of center, but on a portrait display not off its edge.
        let centerX = min(Double(columns) * rng.between(0.56, 0.74), Double(columns) - radius * 1.08)
        let planet = DitherPlanet(
            radius: radius, centerX: centerX, centerY: Double(rows) * rng.between(0.46, 0.6),
            tilt: rng.between(-0.4, 0.4), bands: rng.between(7, 12), offset: rng.between(0, 50)
        )
        let tones = ditherTones().map { [UInt8($0.red8), UInt8($0.green8), UInt8($0.blue8)] }
        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var light = planet.light(column: column, row: row, rows: rows, noise: noise)
                if light.sky, isDark, rng.unit() < 0.0035 { light.value = 0.6 + 0.4 * rng.unit() }
                let level = min(max(Int(light.value * 3 + Self.bayer[(row % 8) * 8 + column % 8]), 0), 3)
                let offset = (row * columns + column) * 4
                pixels.replaceSubrange(offset ..< offset + 3, with: tones[level])
            }
        }
        guard let image = bitmapImage(columns: columns, rows: rows, pixels: pixels) else { return fill(base) }
        let size = CGSize(width: CGFloat(columns) * dot, height: CGFloat(rows) * dot)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: CGPoint(x: 0, y: height - size.height), size: size))
    }

    /// Four tones, darkest first: shades of the accent over the ground.
    private func ditherTones() -> [ThemeColor] {
        let accent = palette.accent
        if isDark {
            return [base, base.mix(accent, 0.28), base.mix(accent, 0.62), accent.mix(palette.brightForeground, 0.55)]
        }
        let paper = palette.background
        return [palette.foreground.mix(accent, 0.25), paper.mix(accent, 0.55), paper.mix(accent, 0.2), paper]
    }
}

/// The 10 PRINT maze: every cell holds one diagonal, splitting it into two triangular
/// halves. Half `2·cell` holds the cell's top edge, `2·cell + 1` its bottom edge.
struct DiagonalMaze {
    let columns: Int
    let rows: Int
    /// Per cell, row-major: `true` for ╱ (bottom-left to top-right), `false` for ╲.
    let rising: [Bool]

    private enum Side {
        case top, right, bottom, left
    }

    /// The half of `cell` that touches `side`.
    private func half(_ cell: Int, _ side: Side) -> Int {
        let upper = switch side {
        case .top: true
        case .bottom: false
        case .right: !rising[cell] // ╲ keeps the right edge with the top, ╱ the left
        case .left: rising[cell]
        }
        return 2 * cell + (upper ? 0 : 1)
    }

    /// For every half, the id of the sealed room it's in, or nil when its region reaches the
    /// edge of the grid.
    func rooms() -> [Int?] {
        var parent = Array(0 ..< columns * rows * 2)
        func root(_ node: Int) -> Int {
            var node = node
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        func join(_ first: Int, _ second: Int) {
            let (firstRoot, secondRoot) = (root(first), root(second))
            if firstRoot != secondRoot { parent[firstRoot] = secondRoot }
        }
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let cell = row * columns + column
                if column + 1 < columns { join(half(cell, .right), half(cell + 1, .left)) }
                if row + 1 < rows { join(half(cell, .bottom), half(cell + columns, .top)) }
            }
        }
        var open = Set<Int>()
        for column in 0 ..< columns {
            open.insert(root(half(column, .top)))
            open.insert(root(half((rows - 1) * columns + column, .bottom)))
        }
        for row in 0 ..< rows {
            open.insert(root(half(row * columns, .left)))
            open.insert(root(half(row * columns + columns - 1, .right)))
        }
        return (0 ..< columns * rows * 2).map { node in
            let room = root(node)
            return open.contains(room) ? nil : room
        }
    }

    /// The corners of `half` in a grid of `cell`-sized squares, y down.
    func triangle(_ half: Int, cell: CGFloat) -> [CGPoint] {
        let index = half / 2
        let left = CGFloat(index % columns) * cell, top = CGFloat(index / columns) * cell
        let right = left + cell, bottom = top + cell
        return switch (rising[index], half.isMultiple(of: 2)) {
        case (false, true): [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom)]
        case (false, false): [CGPoint(x: left, y: top), CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
        case (true, true): [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: left, y: bottom)]
        case (true, false): [CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
        }
    }

    /// The diagonal across cell `index`.
    func wall(_ index: Int, cell: CGFloat) -> [CGPoint] {
        let left = CGFloat(index % columns) * cell, top = CGFloat(index / columns) * cell
        return rising[index]
            ? [CGPoint(x: left, y: top + cell), CGPoint(x: left + cell, y: top)]
            : [CGPoint(x: left, y: top), CGPoint(x: left + cell, y: top + cell)]
    }
}

/// The dither style's scene, in grid pixels with y down: a planet lit from the upper left
/// with tilted bands, a thin atmosphere on its lit side, and a sky brightening downward.
private struct DitherPlanet {
    let radius: Double
    let centerX: Double
    let centerY: Double
    let tilt: Double
    let bands: Double
    let offset: Double

    private static let sun: (x: Double, y: Double, z: Double) = {
        let length = (0.55 * 0.55 + 0.5 * 0.5 + 0.67 * 0.67).squareRoot()
        return (-0.55 / length, -0.5 / length, 0.67 / length)
    }()

    /// Brightness in `0...1` at a grid pixel, and whether it's open sky.
    func light(column: Int, row: Int, rows: Int, noise: ValueNoise) -> (value: Double, sky: Bool) {
        let dx = (Double(column) - centerX) / radius, dy = (Double(row) - centerY) / radius
        let squared = dx * dx + dy * dy, sun = Self.sun
        if squared < 1 {
            let diffuse = max(0, dx * sun.x + dy * sun.y + (1 - squared).squareRoot() * sun.z)
            let across = dy * cos(tilt) + dx * sin(tilt)
            let band = 0.5 + 0.5 * sin(across * bands * 2 + (noise.value(across * 6 + offset, offset) - 0.5) * 3)
            return (0.04 + 0.96 * pow(diffuse, 0.85) * (0.72 + 0.28 * band), false)
        }
        let distance = squared.squareRoot(), facing = (dx * sun.x + dy * sun.y) / distance
        let atmosphere = exp(-(distance - 1) * 14) * min(max(0.35 + 0.65 * facing, 0), 1)
        return (0.03 + 0.16 * pow(Double(row) / Double(rows), 2) + 0.55 * atmosphere, true)
    }
}
