import CoreGraphics
import Foundation

/// A field computed pixel by pixel at full device resolution, on the render lanes: stripes
/// and a sun bent by a gravitational lens. Its edges are filtered analytically, one pixel
/// soft, instead of supersampled.
///
/// Lens is adapted from gart (https://github.com/igr/gart), © 2022 Igor Spasić, BSD 2-Clause License.
extension WallpaperCanvas {
    // MARK: - Lens

    /// Tilted stripes and a sun behind a black hole, seen through its gravitational lens
    /// (after gart's SF14). Every ray bends toward the hole by e²/r, so the stripes wrap
    /// around the Einstein ring and the sun shows twice: a long arc outside the ring and a
    /// short one inside. The lens's Jacobian gives each pixel's stretch, which sets the
    /// width of its box filter.
    mutating func paintLens() {
        let einstein = 240 * Double(unit) * rng.between(0.85, 1.15)
        let center = (x: Double(width) * rng.between(0.3, 0.7), y: Double(height) * rng.between(0.32, 0.68))
        let bearing = rng.between(0, 2 * .pi), offset = rng.between(0.3, 0.7) * einstein
        let phase = rng.unit()
        let tilt = rng.between(18, 42) * (rng.unit() < 0.5 ? 1 : -1) * .pi / 180
        let ink = palette.foreground.mix(base, isDark ? 0.18 : 0.1)
        let lens = GravitationalLens(
            center: center, einstein: einstein,
            sun: (x: center.x + cos(bearing) * offset, y: center.y + sin(bearing) * offset, radius: 0.31 * einstein),
            stripes: (pitch: 31 * Double(unit), phase: phase, normal: (x: -sin(tilt), y: cos(tilt))),
            // Ground, stripe ink, sun, hole. On light themes the hole takes the ink, so it
            // still reads as black.
            tones: [base, ink, palette.accent, isDark ? base : ink].map(PixelTone.init)
        )
        let columns = Int(width)
        paintRows { row, pixels in lens.shade(row: row, columns: columns, into: pixels) }
    }
}

/// A point lens over a plane of stripes and a sun, in device pixels with y down.
private struct GravitationalLens: Sendable {
    let center: (x: Double, y: Double)
    let einstein: Double
    let sun: (x: Double, y: Double, radius: Double)
    let stripes: (pitch: Double, phase: Double, normal: (x: Double, y: Double))
    let tones: [PixelTone]

    /// The share of each stripe period that's inked.
    private static let duty = 0.32

    func shade(row: Int, columns: Int, into pixels: UnsafeMutablePointer<UInt8>) {
        let (ground, ink, bold, hole) = (tones[0], tones[1], tones[2], tones[3])
        let holeRadius = einstein * 0.38
        let y = Double(row) + 0.5, dy = y - center.y
        var column = 0
        while column < columns {
            let x = Double(column) + 0.5, dx = x - center.x, squared = dx * dx + dy * dy
            let dark = clampUnit(0.5 - (squared.squareRoot() - holeRadius))
            var seen = (band: 0.0, sun: 0.0)
            if dark < 1 { seen = sample(x: x, y: y, dx: dx, dy: dy) }
            ground.mixed(ink, seen.band).mixed(bold, seen.sun).mixed(hole, dark).write(to: pixels + column * 4)
            column += 1
        }
    }

    /// How much stripe ink and sun the ray through pixel (x, y) lands on, each box-filtered
    /// over the pixel's footprint on the source plane.
    private func sample(x: Double, y: Double, dx: Double, dy: Double) -> (band: Double, sun: Double) {
        let squared = dx * dx + dy * dy
        let bend = einstein * einstein / squared, change = 2 * bend / squared
        let sourceX = x - bend * dx, sourceY = y - bend * dy
        // The Jacobian of the deflection (symmetric).
        let j11 = 1 - (bend - change * dx * dx), j22 = 1 - (bend - change * dy * dy), j12 = change * dx * dy
        let normal = stripes.normal
        let across = (sourceX * normal.x + sourceY * normal.y) / stripes.pitch + stripes.phase
        let stretchX = j11 * normal.x + j12 * normal.y, stretchY = j12 * normal.x + j22 * normal.y
        let band = Self.stripe(
            across,
            footprint: (stretchX * stretchX + stretchY * stretchY).squareRoot() / stripes.pitch
        )
        let fromSunX = sourceX - sun.x, fromSunY = sourceY - sun.y
        let distance = (fromSunX * fromSunX + fromSunY * fromSunY).squareRoot()
        let radialX = j11 * fromSunX + j12 * fromSunY, radialY = j12 * fromSunX + j22 * fromSunY
        let stretch = (radialX * radialX + radialY * radialY).squareRoot() / distance
        let lit = distance < 1e-4 || stretch < 1e-6
            ? (distance < sun.radius ? 1 : 0)
            : clampUnit(0.5 - (distance - sun.radius) / stretch)
        return (band, lit)
    }

    /// The inked share of `[value − footprint/2, value + footprint/2]` (in stripe periods):
    /// the exact box filter of a square wave, which antialiases without supersampling.
    private static func stripe(_ value: Double, footprint: Double) -> Double {
        if footprint < 1e-4 { return value - floor(value) < duty ? 1 : 0 }
        return clampUnit((inked(value + footprint / 2) - inked(value - footprint / 2)) / footprint)
    }

    /// Ink accumulated from 0 to `value` periods.
    private static func inked(_ value: Double) -> Double {
        let whole = floor(value), part = value - whole
        return whole * duty + (part < duty ? part : duty)
    }
}
