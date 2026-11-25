import CoreGraphics
import CoreText
import Foundation

/// A self-healing cutting mat seen from above, dyed in one of the theme's hues (or black): a
/// printed centimeter or inch grid, rulers numbered around the border, a fan of angle guides
/// on a protractor from one corner, a circle template, and the faint healed scores of old
/// cuts. Drawn in unit space.
extension WallpaperCanvas {
    mutating func paintCuttingMat() {
        enterUnitSpace()
        let inks = MatInks(palette, base: base, color: MatColor.pick(rng.unit()))
        let ruling = MatRuling(metric: rng.unit() < 0.6, width: unitWidth, height: unitHeight)
        paintMatSurface(inks.face)
        paintMatGrid(ruling, ink: inks.print)
        paintMatNumbers(ruling, ink: inks.print)
        paintMatGuides(ruling, ink: inks.guide)
        paintMatScores(ruling, ink: inks.score)
    }

    /// The face: light falling from the top-left, mottled faintly like molded vinyl. Computed
    /// small and stretched, since it only varies over tens of centimeters.
    private func paintMatSurface(_ face: ThemeColor) {
        let columns = 200, rows = max(2, Int(200 * unitHeight / unitWidth))
        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let across = Double(column) / Double(columns - 1), down = Double(row) / Double(rows - 1)
                let light = 0.045 * (1 - 2 * (across * 0.6 + down * 0.4))
                let mottle = (noise.fractal(across * 6, down * 6 * Double(rows) / Double(columns)) - 0.5) * 0.06
                let shade = light + mottle
                let color = shade >= 0 ? face.mix(.white, shade) : face.mix(.black, -shade)
                let index = (row * columns + column) * 4
                pixels[index] = UInt8(color.red8)
                pixels[index + 1] = UInt8(color.green8)
                pixels[index + 2] = UInt8(color.blue8)
            }
        }
        guard let image = bitmapImage(columns: columns, rows: rows, pixels: pixels) else { return fill(face) }
        // Images draw bottom-up; flip back so row 0 lands at the top of unit space.
        context.saveGState()
        context.translateBy(x: 0, y: unitHeight)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: unitWidth, height: unitHeight))
        context.restoreGState()
    }

    // MARK: - Print

    /// The grid inside its frame, every line running on into the border as a ruler tick,
    /// with shorter ticks between: half centimeters and millimeters, or eighths of an inch.
    private func paintMatGrid(_ ruling: MatRuling, ink: ThemeColor) {
        let frame = ruling.frame
        let minor = CGMutablePath(), major = CGMutablePath(), dashed = CGMutablePath(), ticks = CGMutablePath()
        for (index, x) in ruling.lines(ruling.columns, from: frame.minX).enumerated()
            where index > 0 && index < ruling.columns
        {
            (ruling.isMajor(index) ? major : minor).addLines(between: [
                CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY),
            ])
        }
        for (index, y) in ruling.lines(ruling.rows, from: frame.minY).enumerated()
            where index > 0 && index < ruling.rows
        {
            (ruling.isMajor(index) ? major : minor).addLines(between: [
                CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y),
            ])
        }
        if !ruling.metric {
            // Half inches, dashed across the whole grid.
            for column in 0 ..< ruling.columns {
                let x = frame.minX + (CGFloat(column) + 0.5) * ruling.cell
                dashed.addLines(between: [CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY)])
            }
            for row in 0 ..< ruling.rows {
                let y = frame.minY + (CGFloat(row) + 0.5) * ruling.cell
                dashed.addLines(between: [CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y)])
            }
        }
        addMatTicks(ruling, to: ticks)

        stroke(minor, ink, alpha: 0.26, width: 0.55)
        stroke(major, ink, alpha: 0.42, width: 1.05)
        stroke(ticks, ink, alpha: 0.5, width: 0.55)
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [2.4, 2.4])
        stroke(dashed, ink, alpha: 0.22, width: 0.5)
        context.restoreGState()
        stroke(CGPath(rect: frame, transform: nil), ink, alpha: 0.6, width: 1.5)
    }

    /// Ruler ticks on all four sides, pointing out of the frame: longest at the grid lines.
    private func addMatTicks(_ ruling: MatRuling, to path: CGMutablePath) {
        let frame = ruling.frame
        let steps = ruling.tickSteps
        for step in 0 ... ruling.columns * steps {
            let x = frame.minX + CGFloat(step) * ruling.cell / CGFloat(steps)
            let length = ruling.tickLength(step)
            path.addLines(between: [CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.minY - length)])
            path.addLines(between: [CGPoint(x: x, y: frame.maxY), CGPoint(x: x, y: frame.maxY + length)])
        }
        for step in 0 ... ruling.rows * steps {
            let y = frame.minY + CGFloat(step) * ruling.cell / CGFloat(steps)
            let length = ruling.tickLength(step)
            path.addLines(between: [CGPoint(x: frame.minX, y: y), CGPoint(x: frame.minX - length, y: y)])
            path.addLines(between: [CGPoint(x: frame.maxX, y: y), CGPoint(x: frame.maxX + length, y: y)])
        }
    }

    /// Numbers along all four sides of the border, and the unit in the top-left corner.
    private func paintMatNumbers(_ ruling: MatRuling, ink: ThemeColor) {
        let frame = ruling.frame
        let font = CTFontCreateWithName("DINAlternate-Bold" as CFString, ruling.metric ? 8 : 10.5, nil)
        let color = ink.cgColor(alpha: 0.62)
        let gap = MatRuling.tickLength + (ruling.metric ? 9 : 11)
        for (index, x) in ruling.lines(ruling.columns, from: frame.minX).enumerated() where index > 0 {
            matLabel("\(index)", font: font, color: color, at: CGPoint(x: x, y: frame.minY - gap))
            matLabel("\(index)", font: font, color: color, at: CGPoint(x: x, y: frame.maxY + gap))
        }
        for (index, y) in ruling.lines(ruling.rows, from: frame.minY).enumerated() where index > 0 {
            matLabel("\(index)", font: font, color: color, at: CGPoint(x: frame.minX - gap, y: y))
            matLabel("\(index)", font: font, color: color, at: CGPoint(x: frame.maxX + gap, y: y))
        }
        matLabel(
            ruling.metric ? "cm" : "in", font: font, color: color,
            at: CGPoint(x: frame.minX - gap, y: frame.minY - gap)
        )
    }

    // MARK: - Guides

    /// Dashed 30°, 45° and 60° lines fanning out of one corner of the grid over a ticked
    /// protractor arc, and a set of concentric circles toward the far side.
    private mutating func paintMatGuides(_ ruling: MatRuling, ink: ThemeColor) {
        let frame = ruling.frame
        let fromLeft = rng.unit() < 0.5, fromTop = rng.unit() < 0.3
        let corner = CGPoint(x: fromLeft ? frame.minX : frame.maxX, y: fromTop ? frame.minY : frame.maxY)
        let fan = MatFan(corner: corner, rightward: fromLeft, downward: fromTop)
        let radius = ruling.cell * (ruling.metric ? 12 : 5)
        let font = CTFontCreateWithName("DINAlternate-Bold" as CFString, 11, nil)

        context.saveGState()
        context.clip(to: frame)
        let lines = CGMutablePath(), arc = CGMutablePath()
        for degrees in [30.0, 45, 60] {
            lines.addLines(between: [corner, fan.point(degrees, at: frame.width + frame.height)])
        }
        for step in 0 ... 90 {
            let degrees = Double(step), point = fan.point(degrees, at: radius)
            if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
        }
        for degrees in stride(from: 5.0, to: 90, by: 5) {
            let length: CGFloat = degrees.truncatingRemainder(dividingBy: 15) == 0 ? 9 : 5
            arc.addLines(between: [fan.point(degrees, at: radius), fan.point(degrees, at: radius - length)])
        }
        stroke(arc, ink, alpha: 0.55, width: 0.8)
        context.setLineDash(phase: 0, lengths: [8, 5])
        stroke(lines, ink, alpha: 0.5, width: 0.9)
        context.restoreGState()

        for degrees in [30.0, 45, 60] {
            let placement = fan.labelPlacement(degrees, at: radius + 26)
            matLabel(
                "\(Int(degrees))°", font: font, color: ink.cgColor(alpha: 0.7), at: placement.center,
                angle: placement.angle
            )
        }
        paintMatCircles(ruling, ink: ink, awayFrom: corner)
    }

    /// Concentric circles at a grid crossing in the half of the mat away from the fan, with
    /// a crosshair at their center — the template for cutting discs.
    private mutating func paintMatCircles(_ ruling: MatRuling, ink: ThemeColor, awayFrom corner: CGPoint) {
        let frame = ruling.frame
        let step = ruling.metric ? ruling.cell : ruling.cell / 2
        let rings = 5, reach = step * CGFloat(rings) + ruling.cell
        let spanX = max(0, Int((frame.width / 2 - reach * 2) / ruling.cell))
        let spanY = max(0, Int((frame.height - reach * 2) / ruling.cell))
        let offsetX = reach + CGFloat(rng.int(below: spanX + 1)) * ruling.cell
        let offsetY = reach + CGFloat(rng.int(below: spanY + 1)) * ruling.cell
        let x = corner.x == frame.minX ? frame.maxX - offsetX : frame.minX + offsetX
        let y = corner.y == frame.minY ? frame.maxY - offsetY : frame.minY + offsetY
        let center = CGPoint(
            x: frame.minX + ((x - frame.minX) / ruling.cell).rounded() * ruling.cell,
            y: frame.minY + ((y - frame.minY) / ruling.cell).rounded() * ruling.cell
        )
        let circles = CGMutablePath()
        for ring in 1 ... rings {
            let radius = step * CGFloat(ring)
            circles.addEllipse(in: CGRect(origin: center, size: .zero).insetBy(dx: -radius, dy: -radius))
        }
        let arm = step * 0.6
        circles.addLines(between: [CGPoint(x: center.x - arm, y: center.y), CGPoint(x: center.x + arm, y: center.y)])
        circles.addLines(between: [CGPoint(x: center.x, y: center.y - arm), CGPoint(x: center.x, y: center.y + arm)])
        stroke(circles, ink, alpha: 0.45, width: 0.8)
    }

    // MARK: - Wear

    /// Healed knife scores: bundles of near-parallel cuts where a straightedge lay (mostly
    /// against a printed line), plus loose short nicks. Each fades in and out like a blade
    /// entering and leaving the vinyl.
    private mutating func paintMatScores(_ ruling: MatRuling, ink: ThemeColor) {
        let area = ruling.frame.insetBy(dx: -20, dy: -20)
        var cuts: [(CGPoint, CGPoint)] = []
        for _ in 0 ..< 6 + rng.int(below: 5) {
            cuts += straightedgeCuts(ruling, in: area)
        }
        for _ in 0 ..< 8 + rng.int(below: 9) {
            let angle = CGFloat(rng.between(0, .pi)), length = CGFloat(rng.between(8, 55))
            let start = randomPoint(in: area)
            cuts.append((start, CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)))
        }
        context.setLineCap(.butt)
        context.setLineWidth(hairline(0.6))
        let pieces = 10
        for (start, end) in cuts {
            let peak = rng.between(0.14, 0.3)
            for piece in 0 ..< pieces {
                let from = CGFloat(piece) / CGFloat(pieces), to = CGFloat(piece + 1) / CGFloat(pieces)
                let fade = sin(Double(from + to) / 2 * .pi).squareRoot()
                context.setStrokeColor(ink.cgColor(alpha: peak * fade))
                let segment = [start.interpolated(to: end, from), start.interpolated(to: end, to)]
                context.strokeLineSegments(between: segment)
            }
        }
    }

    /// One to four cuts along a straightedge: usually laid just beside a printed line,
    /// sometimes at any angle. Each pass wanders a hair off the last and runs a little shorter.
    private mutating func straightedgeCuts(_ ruling: MatRuling, in area: CGRect) -> [(CGPoint, CGPoint)] {
        var angle = CGFloat(rng.between(0, .pi)), center = randomPoint(in: area)
        if rng.unit() < 0.7 {
            let beside = CGFloat(rng.between(1, 3.5)) * (rng.unit() < 0.5 ? -1 : 1)
            if rng.unit() < 0.5 {
                angle = .pi / 2
                center.x = ruling.nearestLine(across: center.x) + beside
            } else {
                angle = 0
                center.y = ruling.nearestLine(down: center.y) + beside
            }
        }
        let length = ruling.cell * CGFloat(rng.between(ruling.metric ? 6 : 2.5, ruling.metric ? 24 : 10))
        let normal = CGPoint(x: -sin(angle), y: cos(angle))
        return (0 ..< 1 + rng.int(below: 4)).map { _ in
            let tilt = angle + CGFloat(rng.between(-0.004, 0.004)), shift = CGFloat(rng.between(-0.7, 0.7))
            let direction = CGPoint(x: cos(tilt), y: sin(tilt))
            let mid = CGPoint(x: center.x + normal.x * shift, y: center.y + normal.y * shift)
            let start = (CGFloat(rng.between(0, 0.2)) - 0.5) * length
            let end = (0.5 - CGFloat(rng.between(0, 0.2))) * length
            return (
                CGPoint(x: mid.x + direction.x * start, y: mid.y + direction.y * start),
                CGPoint(x: mid.x + direction.x * end, y: mid.y + direction.y * end)
            )
        }
    }

    private mutating func randomPoint(in area: CGRect) -> CGPoint {
        CGPoint(x: area.minX + CGFloat(rng.unit()) * area.width, y: area.minY + CGFloat(rng.unit()) * area.height)
    }

    // MARK: - Helpers

    private func stroke(_ path: CGPath, _ ink: ThemeColor, alpha: Double, width: CGFloat) {
        context.addPath(path)
        context.setStrokeColor(ink.cgColor(alpha: alpha))
        context.setLineWidth(hairline(width))
        context.strokePath()
    }

    /// Text centered on `center`, turned by `angle` (unit space points down, glyphs need up).
    private func matLabel(_ text: String, font: CTFont, color: CGColor, at center: CGPoint, angle: CGFloat = 0) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.setShouldSmoothFonts(false)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// The colors mats are sold in, each taken from the theme: the classic green most often,
/// then blue, black, teal, pink and red. Black is a frosted white mat on a light theme.
enum MatColor: CaseIterable {
    case green, blue, black, teal, pink, red

    /// How often the seed lands on each, in `allCases` order.
    private static let weights = [0.3, 0.2, 0.2, 0.1, 0.1, 0.1]

    static func pick(_ roll: Double) -> MatColor {
        var remaining = roll
        for (color, weight) in zip(allCases, weights) {
            remaining -= weight
            if remaining < 0 { return color }
        }
        return .green
    }

    /// The theme hue the mat is dyed in, or nil for the neutral mat.
    func hue(in palette: ThemePalette) -> ThemeColor? {
        switch self {
        case .green: palette.green
        case .blue: palette.blue
        case .teal: palette.cyan
        case .pink: palette.magenta
        case .red: palette.red
        case .black: nil
        }
    }
}

/// The mat's colors: its face, printed lines in the foreground (or a deep shade of the face
/// on a light mat), guides in yellow — blue on a mat whose own hue is near yellow, red on a
/// white one — and cuts that catch the light.
private struct MatInks {
    let face: ThemeColor
    let print: ThemeColor
    let guide: ThemeColor
    let score: ThemeColor

    init(_ palette: ThemePalette, base: ThemeColor, color: MatColor) {
        let dark = palette.mode == .dark
        let hue = color.hue(in: palette)
        let nearYellow = hue.map { ThemeColor.hueDistance($0.hsl.hue, palette.yellow.hsl.hue) < 60 } ?? false
        let guideHue = nearYellow ? palette.blue : palette.yellow
        switch (hue, dark) {
        case let (hue?, true):
            face = hue.mix(base, 0.66)
            print = palette.foreground.mix(hue, 0.2)
            guide = guideHue.mix(palette.foreground, 0.15)
        case let (hue?, false):
            face = hue.mix(palette.background, 0.6)
            print = hue.mix(palette.foreground, 0.55)
            guide = guideHue.mix(palette.foreground, 0.45)
        case (nil, true):
            face = base.mix(.black, 0.3)
            print = palette.foreground.mix(face, 0.15)
            guide = palette.yellow.mix(palette.foreground, 0.15)
        case (nil, false):
            face = palette.background.mix(palette.foreground, 0.05)
            print = palette.foreground.mix(face, 0.3)
            guide = palette.red.mix(palette.foreground, 0.2)
        }
        score = dark ? face.mix(.white, 0.55) : face.mix(.black, 0.45)
    }
}

/// The printed grid: a centimeter or inch cell (about 40 cm of mat span the screen's
/// height), as many whole cells as fit inside a border for the rulers, centered.
private struct MatRuling {
    static let centimeter: CGFloat = 25
    /// How far the grid lines run on into the border.
    static let tickLength: CGFloat = 6

    let metric: Bool
    let cell: CGFloat
    let columns: Int
    let rows: Int
    let frame: CGRect

    init(metric: Bool, width: CGFloat, height: CGFloat) {
        self.metric = metric
        cell = metric ? Self.centimeter : Self.centimeter * 2.54
        let border: CGFloat = 36
        columns = max(1, Int((width - border * 2) / cell))
        rows = max(1, Int((height - border * 2) / cell))
        let size = CGSize(width: CGFloat(columns) * cell, height: CGFloat(rows) * cell)
        frame = CGRect(
            x: (width - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height
        )
    }

    /// Every 5 cm is bold on a metric mat; on an inch mat every inch is (halves are dashed).
    func isMajor(_ index: Int) -> Bool {
        metric ? index.isMultiple(of: 5) : true
    }

    /// Ticks per cell in the border: millimeters, or eighths of an inch.
    var tickSteps: Int {
        metric ? 10 : 8
    }

    func tickLength(_ step: Int) -> CGFloat {
        if step.isMultiple(of: tickSteps) { return Self.tickLength }
        if step.isMultiple(of: tickSteps / 2) { return Self.tickLength * 0.7 }
        if !metric, step.isMultiple(of: 2) { return Self.tickLength * 0.5 }
        return Self.tickLength * 0.35
    }

    /// Positions of the `count + 1` lines bounding `count` cells.
    func lines(_ count: Int, from start: CGFloat) -> [CGFloat] {
        (0 ... count).map { start + CGFloat($0) * cell }
    }

    func nearestLine(across x: CGFloat) -> CGFloat {
        frame.minX + min(max(((x - frame.minX) / cell).rounded(), 0), CGFloat(columns)) * cell
    }

    func nearestLine(down y: CGFloat) -> CGFloat {
        frame.minY + min(max(((y - frame.minY) / cell).rounded(), 0), CGFloat(rows)) * cell
    }
}

/// Angles measured from a corner of the grid's frame, into the grid.
private struct MatFan {
    let corner: CGPoint
    let rightward: Bool
    let downward: Bool

    func direction(_ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: (rightward ? 1 : -1) * cos(radians), y: (downward ? 1 : -1) * sin(radians))
    }

    func point(_ degrees: Double, at distance: CGFloat) -> CGPoint {
        let direction = direction(degrees)
        return CGPoint(x: corner.x + direction.x * distance, y: corner.y + direction.y * distance)
    }

    /// Where a label rides just above the guide line, turned along it but kept upright.
    func labelPlacement(_ degrees: Double, at distance: CGFloat) -> (center: CGPoint, angle: CGFloat) {
        let direction = direction(degrees)
        var angle = atan2(direction.y, direction.x)
        if abs(angle) > .pi / 2 { angle += angle > 0 ? -.pi : .pi }
        let along = point(degrees, at: distance), lift: CGFloat = 7
        return (CGPoint(x: along.x + sin(angle) * lift, y: along.y - cos(angle) * lift), angle)
    }
}
