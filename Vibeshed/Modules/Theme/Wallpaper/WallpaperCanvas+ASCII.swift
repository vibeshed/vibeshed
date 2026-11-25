import CoreGraphics
import CoreText
import Foundation

/// ASCII art on a terminal grid, one of three classics picked by the seed: a lit torus after
/// Andy Sloane's `donut.c`, the Mandelbrot set as BASIC listings printed it, or aalib's
/// `aafire` (the last two in `WallpaperCanvas+ASCIIScenes`). All are shaded with donut.c's
/// `.,-~:;=!*#$@` ramp over a dim plasma or a few stars. Glyphs are real Menlo in cells twice
/// as tall as wide, so the picture keeps the proportions of an 80-column screen.
extension WallpaperCanvas {
    /// Light to dense; on a dark ground density reads as brightness.
    static let asciiRamp = Array(".,-~:;=!*#$@")
    /// The ramp, then extra characters for the starfield.
    private static let asciiCharacters = asciiRamp + ["+"]

    mutating func paintASCII() {
        fill(palette["desktop"] ?? base)
        let subject = rng.int(below: 3)
        // The Mandelbrot set gets a finer grid: its edge is all detail.
        let rows = Int(((subject == 1 ? 90 : 60) * heightRatio).rounded())
        let grid = ASCIIGrid(width: width, height: height, rows: rows)
        let figure = switch subject {
        case 0: torusFigure(grid: grid)
        case 1: mandelbrotFigure(grid: grid)
        default: fireFigure(grid: grid)
        }
        glow(figure.glowColor, at: figure.glowCenter, radius: figure.glowRadius, alpha: isDark ? 0.16 : 0.1)
        var cells = backgroundCells(grid: grid, figure: figure.marks, haze: figure.haze)
        for (index, mark) in figure.marks.enumerated() {
            guard let mark else { continue }
            cells.append(ASCIICell(
                column: index % grid.columns, row: index / grid.columns, glyph: mark.glyph, color: mark.color
            ))
        }
        drawGlyphs(cells, grid: grid)
    }

    /// The torus, about 56% of a landscape screen's height, near the middle.
    private mutating func torusFigure(grid: ASCIIGrid) -> ASCIIFigure {
        let torus = ASCIITorus(
            tilt: rng.between(0.55, 1.25), turn: rng.between(0.2, 1.1), spin: rng.between(0, .pi * 2)
        )
        let center = (column: Double(grid.columns) * rng.between(0.44, 0.56), row: Double(grid.rows) * 0.5)
        let levels = torus.render(
            columns: grid.columns, rows: grid.rows, center: center,
            halfHeight: Double(grid.rows) / Double(heightRatio) * 0.28
        )
        let ramp = Self.asciiRamp.count
        let shades = asciiShades(isDark
            ? [muted(harmony(3).last ?? palette.accent, 0.35), palette.accent.mix(base, 0.2), palette.accent,
               palette.accent.mix(palette.brightForeground, 0.7)]
            : [palette.background.mix(palette.accent, 0.45), palette.accent,
               palette.accent.mix(palette.foreground, 0.45), palette.foreground])
        return ASCIIFigure(
            marks: levels.map { level in
                level.map {
                    // Paper ASCII art is dark where it's dense, so a light ground inverts the
                    // ramp, short of its densest characters so the shadow side isn't a wall.
                    ASCIIMark(glyph: isDark ? $0 : (ramp - 1 - $0) * 3 / 4, color: shades[$0])
                }
            },
            glowCenter: CGPoint(x: CGFloat(center.column) * grid.cellWidth, y: height / 2),
            glowRadius: unit * 420, glowColor: palette.accent, haze: true
        )
    }

    /// One color per ramp level, blended through `stops`, lightest level first.
    func asciiShades(_ stops: [ThemeColor]) -> [ThemeColor] {
        let count = Self.asciiRamp.count
        return (0 ..< count).map { level in
            let position = Double(level) / Double(count - 1) * Double(stops.count - 1)
            let index = min(Int(position), stops.count - 2)
            return stops[index].mix(stops[index + 1], position - Double(index))
        }
    }

    /// A few stars and, with `haze`, a faint plasma of the ramp's light end in muted harmony
    /// hues, kept a few cells clear of the figure so its silhouette reads.
    private mutating func backgroundCells(grid: ASCIIGrid, figure: [ASCIIMark?], haze: Bool) -> [ASCIICell] {
        var clear = [Bool](repeating: false, count: figure.count)
        for index in figure.indices where figure[index] != nil {
            let (column, row) = (index % grid.columns, index / grid.columns)
            for near in max(0, row - 1) ... min(grid.rows - 1, row + 1) {
                for across in max(0, column - 3) ... min(grid.columns - 1, column + 3) {
                    clear[near * grid.columns + across] = true
                }
            }
        }
        let hazes = harmony(3).map { muted($0, 0.8) }
        let star = muted(palette.brightForeground, isDark ? 0.4 : 0.35)
        let stars = [0, 0, 8, Self.asciiCharacters.count - 1] // . . * +
        let scale = (x: rng.between(0.025, 0.04), y: rng.between(0.05, 0.08))
        var cells = [ASCIICell]()
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns where !clear[row * grid.columns + column] {
                if rng.unit() < 0.005 {
                    cells.append(ASCIICell(column: column, row: row, glyph: rng.pick(stars), color: star))
                    continue
                }
                guard haze else { continue }
                let value = noise.fractal(Double(column) * scale.x, Double(row) * scale.y, octaves: 3)
                let level = Int((value - 0.5) * 16)
                guard level >= 0 else { continue }
                let hue = noise.value(Double(column) * 0.02 + 40, Double(row) * 0.04)
                cells.append(ASCIICell(
                    column: column, row: row, glyph: min(level, 3),
                    color: hazes[min(Int(hue * Double(hazes.count)), hazes.count - 1)]
                ))
            }
        }
        return cells
    }

    /// Draws each cell's ramp character in Menlo, batched by color and glyph.
    private func drawGlyphs(_ cells: [ASCIICell], grid: ASCIIGrid) {
        let probe = CTFontCreateWithName("Menlo-Bold" as CFString, 100, nil)
        var characters = Self.asciiCharacters.map { UniChar($0.unicodeScalars.first?.value ?? 32) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(probe, &characters, &glyphs, characters.count)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(probe, .horizontal, &glyphs, &advance, 1)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 100 * grid.cellWidth / max(advance.width, 1), nil)
        let baseline = (grid.cellHeight - CTFontGetAscent(font) + CTFontGetDescent(font)) / 2

        var batches: [ASCIIBatchKey: [CGPoint]] = [:]
        // Batches draw in first-seen order: antialiased edges of neighboring glyphs overlap,
        // and a dictionary's iteration order differs between instances, so iterating it
        // made the same seed render differently from one draw to the next.
        var order: [ASCIIBatchKey] = []
        for cell in cells {
            let origin = CGPoint(
                x: CGFloat(cell.column) * grid.cellWidth,
                y: height - CGFloat(cell.row + 1) * grid.cellHeight + baseline
            )
            let key = ASCIIBatchKey(color: cell.color, glyph: cell.glyph)
            if batches[key] == nil {
                order.append(key)
            }
            batches[key, default: []].append(origin)
        }
        context.saveGState()
        context.textMatrix = .identity
        context.setShouldSmoothFonts(false)
        for key in order {
            let positions = batches[key] ?? []
            context.setFillColor(key.color.cgColor)
            let run = [CGGlyph](repeating: glyphs[key.glyph], count: positions.count)
            CTFontDrawGlyphs(font, run, positions, positions.count, context)
        }
        context.restoreGState()
    }
}

/// The character grid, sized by row count; cells are twice as tall as wide.
struct ASCIIGrid {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let columns: Int
    let rows: Int

    init(width: CGFloat, height: CGFloat, rows: Int) {
        cellHeight = height / CGFloat(rows)
        cellWidth = cellHeight / 2
        columns = Int((width / cellWidth).rounded(.up))
        self.rows = rows
    }
}

/// What a figure puts in one cell.
struct ASCIIMark {
    let glyph: Int
    let color: ThemeColor
}

/// One of the style's subjects: a mark per cell (row-major, nil where it's empty) and the
/// glow painted behind it.
struct ASCIIFigure {
    let marks: [ASCIIMark?]
    let glowCenter: CGPoint
    let glowRadius: CGFloat
    let glowColor: ThemeColor
    /// Whether the plasma fills the background (otherwise it's only stars).
    let haze: Bool
}

private struct ASCIICell {
    let column: Int
    let row: Int
    let glyph: Int
    let color: ThemeColor
}

private struct ASCIIBatchKey: Hashable {
    let color: ThemeColor
    let glyph: Int
}

/// `donut.c`'s torus (tube radius 1, ring radius 2, five units from the eye), turned by
/// three angles, point-sampled into a z-buffered character grid.
struct ASCIITorus {
    let tilt: Double
    let turn: Double
    let spin: Double

    private static let tube = 1.0
    private static let ring = 2.0
    private static let distance = 5.0

    /// Toward the upper left and the viewer (who looks down +z, y up).
    private static let light: (x: Double, y: Double, z: Double) = {
        let length = (0.5 * 0.5 + 0.7 * 0.7 + 0.6 * 0.6).squareRoot()
        return (-0.5 / length, 0.7 / length, -0.6 / length)
    }()

    private struct Vector {
        var x: Double
        var y: Double
        var z: Double
    }

    /// Per cell, row-major: the ramp level of the nearest surface, or nil where the torus
    /// isn't. Scaled so its projection is `halfHeight` rows above and below `center`.
    func render(columns: Int, rows: Int, center: (column: Double, row: Double), halfHeight: Double) -> [Int?] {
        // A coarse pass finds the projection's extent, so any turn fits the frame.
        var bounds = (minX: Double.infinity, maxX: -Double.infinity, minY: Double.infinity, maxY: -Double.infinity)
        sample(tubeStep: 0.1, ringStep: 0.05) { point, _ in
            let (x, y) = (point.x / point.z, point.y / point.z)
            bounds = (min(bounds.minX, x), max(bounds.maxX, x), min(bounds.minY, y), max(bounds.maxY, y))
        }
        let extent = (x: (bounds.maxX - bounds.minX) / 2, y: (bounds.maxY - bounds.minY) / 2,
                      midX: (bounds.maxX + bounds.minX) / 2, midY: (bounds.maxY + bounds.minY) / 2)
        // Rows are twice the height of columns, so one unit of y is half as many rows.
        let scale = min(halfHeight * 2 / max(extent.y, 1e-6), Double(columns) * 0.32 / max(extent.x, 1e-6))

        var depth = [Double](repeating: 0, count: columns * rows)
        var levels = [Int?](repeating: nil, count: columns * rows)
        let ramp = WallpaperCanvas.asciiRamp.count
        // Fine enough that neighboring samples land under half a cell apart on the near side
        // (z ≈ 2), where the ring moves 3 units per radian and the tube 1.
        sample(tubeStep: 0.8 / scale, ringStep: 0.3 / scale) { point, normal in
            let inverse = 1 / point.z
            let column = Int(center.column + scale * (point.x * inverse - extent.midX))
            let row = Int(center.row - scale * (point.y * inverse - extent.midY) / 2)
            guard column >= 0, column < columns, row >= 0, row < rows else { return }
            let index = row * columns + column
            guard inverse > depth[index] else { return }
            depth[index] = inverse
            levels[index] = min(Int(Self.luminance(at: point, normal: normal) * Double(ramp)), ramp - 1)
        }
        return levels
    }

    /// Ambient, diffuse and a Blinn–Phong highlight, so the shadowed side still shows as
    /// the ramp's light end and the lit side peaks in `@`.
    private static func luminance(at point: Vector, normal: Vector) -> Double {
        let diffuse = max(0, normal.x * light.x + normal.y * light.y + normal.z * light.z)
        let length = (point.x * point.x + point.y * point.y + point.z * point.z).squareRoot()
        var half = Vector(x: light.x - point.x / length, y: light.y - point.y / length, z: light.z - point.z / length)
        let halfLength = (half.x * half.x + half.y * half.y + half.z * half.z).squareRoot()
        half = Vector(x: half.x / halfLength, y: half.y / halfLength, z: half.z / halfLength)
        let specular = pow(max(0, normal.x * half.x + normal.y * half.y + normal.z * half.z), 24)
        return min(0.14 + 0.66 * diffuse + 0.4 * specular, 1)
    }

    /// Visits surface points (in eye space) with their unit normals.
    private func sample(tubeStep: Double, ringStep: Double, _ visit: (Vector, Vector) -> Void) {
        let (sinTilt, cosTilt, sinTurn, cosTurn) = (sin(tilt), cos(tilt), sin(turn), cos(turn))
        func rotate(_ vector: Vector, _ sinRing: Double, _ cosRing: Double) -> Vector {
            // About y by the ring angle (sweeping the circle into a torus), spun, then tilted
            // about x and turned about z.
            let spun = Vector(x: vector.x * cosRing + vector.z * sinRing, y: vector.y,
                              z: -vector.x * sinRing + vector.z * cosRing)
            let tilted = Vector(x: spun.x, y: spun.y * cosTilt - spun.z * sinTilt,
                                z: spun.y * sinTilt + spun.z * cosTilt)
            return Vector(x: tilted.x * cosTurn - tilted.y * sinTurn, y: tilted.x * sinTurn + tilted.y * cosTurn,
                          z: tilted.z)
        }
        var theta = 0.0
        while theta < .pi * 2 {
            let (sinTheta, cosTheta) = (sin(theta), cos(theta))
            let circle = Vector(x: Self.ring + Self.tube * cosTheta, y: Self.tube * sinTheta, z: 0)
            let normal = Vector(x: cosTheta, y: sinTheta, z: 0)
            var phi = spin
            while phi < spin + .pi * 2 {
                let (sinPhi, cosPhi) = (sin(phi), cos(phi))
                var point = rotate(circle, sinPhi, cosPhi)
                point.z += Self.distance
                visit(point, rotate(normal, sinPhi, cosPhi))
                phi += ringStep
            }
            theta += tubeStep
        }
    }
}
