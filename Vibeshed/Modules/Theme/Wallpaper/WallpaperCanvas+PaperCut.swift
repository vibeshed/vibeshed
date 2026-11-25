import CoreGraphics
import Foundation

/// Cut paper: wavy sheets hanging from the top in two families, each casting a soft shadow
/// on the ones behind, with a sun tucked between the families. Drawn in unit space.
///
/// Adapted from gart (https://github.com/igr/gart), © 2022 Igor Spasić, BSD 2-Clause License.
extension WallpaperCanvas {
    /// Layered paper sheets with soft drop shadows (after gart's Strata): four darker sheets
    /// behind a gradient sun and five lighter ones in front. Their edges are B-spline waves
    /// that all rise at one crest, and the deepest front sheet cuts across the top of the sun.
    mutating func paintPaperCut() {
        enterUnitSpace()
        let tones = paperTones()
        let gap = 95.45 * heightRatio * rng.between(0.9, 1.1), wave = rng.between(150, 195)
        let crest = rng.between(0.25, 0.75), drift = rng.between(-0.02, 0.02), opening = rng.between(0.44, 0.52)
        let edges = PaperEdges(
            width: Double(unitWidth), crest: crest, drift: drift,
            shared: (0 ..< PaperEdges.anchors).map { _ in rng.unit() * 2 - 1 }
        )
        linear(tones.ground, from: CGPoint(x: 0, y: 600 * heightRatio), to: CGPoint(x: unitWidth, y: unitHeight))
        let lowerStart = unitHeight * opening + gap * 0.28
        for layer in stride(from: 3, through: 0, by: -1) {
            let depth = Double(layer) / 3
            let edge = edges.edge(
                mean: lowerStart + Double(layer) * gap, amplitude: wave * (0.64 + 0.12 * depth),
                centered: Double(layer) - 1.5, lower: true, using: &rng
            )
            paintSheet(edge, color: tones.lower(depth), shadow: tones.shadow)
        }
        paintPaperSun(
            crestX: Double(unitWidth) * crest, crestY: unitHeight * opening - wave, colors: tones.sun,
            shadowAlpha: tones.shadowAlpha
        )
        for layer in stride(from: 4, through: 0, by: -1) {
            let depth = Double(layer) / 4
            let edge = edges.edge(
                mean: unitHeight * opening - Double(4 - layer) * gap, amplitude: wave * (0.34 + 0.66 * depth),
                centered: Double(layer) - 2, lower: false, using: &rng
            )
            paintSheet(edge, color: tones.upper(depth), shadow: tones.shadow)
        }
    }

    /// One sheet: everything above `edge`, shaded corner to corner, over its drop shadow.
    private func paintSheet(_ edge: [CGPoint], color: ThemeColor, shadow: CGColor) {
        let sheet = CGMutablePath()
        sheet.addLines(between: edge + [
            CGPoint(x: unitWidth * 1.18, y: -120), CGPoint(x: -unitWidth * 0.18, y: -120),
        ])
        sheet.closeSubpath()
        // Only a strip along the edge casts a shadow anyone sees (the sheet covers the rest
        // of its own), and blurring that strip costs a fraction of blurring the whole sheet.
        let caster = CGMutablePath()
        caster.addLines(between: edge + edge.reversed().map { CGPoint(x: $0.x, y: $0.y - 110) })
        caster.closeSubpath()
        context.saveGState()
        // Shadows are set in device space, which isn't flipped: down is negative.
        context.setShadow(offset: CGSize(width: 0, height: -16.4 * unit), blur: 32.7 * unit, color: shadow)
        context.addPath(caster)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(sheet)
        context.clip()
        let shades = [color.lightened(0.0385), color, color.darkened(0.07)]
        linear(shades, from: .zero, to: CGPoint(x: unitWidth, y: unitHeight))
        context.restoreGState()
    }

    /// The sun, just under the deepest front sheet where it rides highest: a tilted
    /// gradient oval with its own shadow and two faint warm bands across its lower part.
    private mutating func paintPaperSun(crestX: Double, crestY: Double, colors: [ThemeColor], shadowAlpha: Double) {
        let radiusY = 1000 * rng.between(0.16, 0.2), radiusX = radiusY * rng.between(1.0, 1.12)
        let center = CGPoint(
            x: crestX + Double(unitWidth) * rng.between(-0.04, 0.04),
            y: crestY + radiusY * rng.between(0.35, 0.7)
        )
        let tilt = rng.between(-24, 24) * .pi / 180
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: tilt)
        let oval = CGPath(
            ellipseIn: CGRect(x: -radiusX, y: -radiusY, width: radiusX * 2, height: radiusY * 2), transform: nil
        )
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10.2 * unit), blur: 37.6 * unit,
            color: CGColor(srgbRed: 5 / 255, green: 7 / 255, blue: 12 / 255, alpha: shadowAlpha * 0.86)
        )
        context.addPath(oval)
        context.setFillColor(colors[1].cgColor)
        context.fillPath()
        context.restoreGState()
        context.addPath(oval)
        context.clip()
        linear(colors, from: CGPoint(x: -radiusX * 0.24, y: -radiusY), to: CGPoint(x: radiusX * 0.18, y: radiusY))
        let spread = radiusX * 1.34
        for (top, rise, alpha) in [(-radiusY * 0.16, radiusY * 0.24, 0.12), (radiusY * 0.3, radiusY * 0.28, 0.15)] {
            // A dome across the sun with everything under it lit.
            let dome = CGMutablePath()
            dome.addLines(between: (0 ... 32).map { step in
                let angle = Double.pi * (1 + Double(step) / 32)
                return CGPoint(x: spread * cos(angle), y: top + rise * sin(angle))
            } + [CGPoint(x: spread, y: top + radiusY * 1.65), CGPoint(x: -spread, y: top + radiusY * 1.65)])
            dome.closeSubpath()
            context.addPath(dome)
            context.setFillColor(CGColor(srgbRed: 1, green: 232 / 255, blue: 180 / 255, alpha: alpha))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// Cool sheets and a warm sun: whichever side the accent falls on keeps it.
    private func paperTones() -> PaperTones {
        func warm(_ color: ThemeColor) -> Bool {
            color.hsl.hue < 75 || color.hsl.hue > 320
        }
        let hues = harmony(7, keepingTwin: true), accentIsWarm = warm(palette.accent)
        let sheetIndex = accentIsWarm ? hues.firstIndex { !warm($0) } : 0
        let sheet = sheetIndex.map { hues[$0] } ?? palette.blue
        // The next cool hue in the list, which is the accent's twin when it has one.
        let backing = hues.indices.first { $0 != sheetIndex && !warm(hues[$0]) }.map { hues[$0] } ?? palette.cyan
        let sun = accentIsWarm ? palette.accent : palette.orange != palette.yellow ? palette.orange : palette.red
        return PaperTones(
            sheet: sheet, backing: backing, base: base, background: palette.background, isDark: isDark,
            sun: [
                sun.mix(palette.yellow, 0.55).mix(.white, isDark ? 0.12 : 0), sun,
                sun.mix(palette.red, 0.45).darkened(0.08),
            ]
        )
    }
}

/// The paper style's colors. Depth runs from 0 for the front sheet of a family to 1 for its
/// deepest.
private struct PaperTones {
    let sheet: ThemeColor
    let backing: ThemeColor
    let base: ThemeColor
    let background: ThemeColor
    let isDark: Bool
    let sun: [ThemeColor]

    func upper(_ depth: Double) -> ThemeColor {
        let tone = sheet.mix(backing, depth * 0.6)
        return isDark ? tone.mix(base, 0.08 + 0.54 * depth) : tone.mix(background, 0.72 - 0.57 * depth)
    }

    func lower(_ depth: Double) -> ThemeColor {
        let tone = backing.mix(sheet, depth * 0.4)
        return isDark ? tone.mix(base, 0.42 + 0.24 * depth) : tone.darkened(0.15 + 0.17 * depth)
    }

    var ground: [ThemeColor] {
        isDark ? [backing.mix(base, 0.8), base.darkened(0.3)] : [backing.darkened(0.35), backing.darkened(0.5)]
    }

    var shadowAlpha: Double {
        isDark ? 0.46 : 0.3
    }

    /// Near black on dark themes; on light ones, the sheet color darkened.
    var shadow: CGColor {
        isDark
            ? CGColor(srgbRed: 2 / 255, green: 7 / 255, blue: 13 / 255, alpha: shadowAlpha)
            : sheet.darkened(0.6).cgColor(alpha: shadowAlpha)
    }
}

/// The cut edges, y down: twelve anchors spanning the width plus 18% on each side, waving
/// up to a crest, jittered partly in step across all sheets, then smoothed by a B-spline.
struct PaperEdges {
    static let anchors = 12

    let width: Double
    let crest: Double
    let drift: Double
    /// The jitter every sheet shares at each anchor, in −1…1.
    let shared: [Double]

    /// The edge of a sheet `centered` layers from the middle of its family.
    func edge(
        mean: Double, amplitude: Double, centered: Double, lower: Bool, using rng: inout SeededGenerator
    ) -> [CGPoint] {
        let crest = self.crest + (lower ? -0.022 : 0) + centered * drift
        let secondaryPhase = rng.unit() * 0.16 - 0.08 + (lower ? 0.12 : 0)
        let margin = width * 0.18
        let points = (0 ..< Self.anchors).map { anchor -> CGPoint in
            let x = -margin + (width + margin * 2) * Double(anchor) / Double(Self.anchors - 1), along = x / width
            let dominant = -cos(2 * .pi * (along - crest))
            let secondary = sin(4 * .pi * (along - self.crest * 0.35 + secondaryPhase))
            let jitter = 16.4 * (shared[anchor] * 0.68 + (rng.unit() * 2 - 1) * 0.32)
            return CGPoint(x: x, y: mean + amplitude * (dominant + 0.16 * secondary) + jitter)
        }
        let first = points[0], last = points[points.count - 1]
        return Self.bSpline([first, first] + points + [last, last], samples: 24)
    }

    /// A uniform cubic B-spline through `points` (repeat the ends to clamp it), `samples`
    /// points per segment, ending on the last point.
    static func bSpline(_ points: [CGPoint], samples: Int) -> [CGPoint] {
        var curve: [CGPoint] = []
        for index in 0 ..< max(points.count - 3, 0) {
            let (p0, p1, p2, p3) = (points[index], points[index + 1], points[index + 2], points[index + 3])
            for sample in 0 ..< samples {
                let along = Double(sample) / Double(samples), squared = along * along, cubed = squared * along
                let weights = (
                    (1 - along) * (1 - along) * (1 - along), 3 * cubed - 6 * squared + 4,
                    -3 * cubed + 3 * squared + 3 * along + 1, cubed
                )
                curve.append(CGPoint(
                    x: (weights.0 * p0.x + weights.1 * p1.x + weights.2 * p2.x + weights.3 * p3.x) / 6,
                    y: (weights.0 * p0.y + weights.1 * p1.y + weights.2 * p2.y + weights.3 * p3.y) / 6
                ))
            }
        }
        if let last = points.last { curve.append(last) }
        return curve
    }
}
