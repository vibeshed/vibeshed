import CoreGraphics
import Foundation

/// Windows desktops: 95's Clouds, XP's Azul and the one-bit patterns of Windows 3.0 and 95.
/// The skies take a theme's `sky` key, or its blue at daylight lightness.
extension WallpaperCanvas {
    /// The daytime sky color.
    var daySky: ThemeColor {
        palette["sky"] ?? ThemeColor(hue: palette.blue.hsl.hue, saturation: 0.62, lightness: 0.56)
    }

    /// A soft-edged disc: solid in the middle, fading out over its outer half.
    func puff(_ color: ThemeColor, at center: CGPoint, radius: CGFloat, alpha: Double = 1) {
        let colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: alpha * 0.85), color.cgColor(alpha: 0)]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.5, 1])
        else { return }
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
        )
    }

    // MARK: - Clouds

    /// Windows 95's Clouds: white cumulus over a blue sky, painted at a quarter of 4K's
    /// resolution and reduced to 32 levels a channel (15-bit color) with Bayer dithering,
    /// then scaled up without smoothing.
    mutating func paintClouds() {
        let dot = max(1, (height / 540).rounded())
        let columns = Int((width / dot).rounded(.up)), rows = Int((height / dot).rounded(.up))
        guard var sky = WallpaperCanvas(
            size: CGSize(width: columns, height: rows), palette: palette, seed: rng.next()
        ), let data = sky.context.data
        else { return fill(daySky) }
        sky.paintCloudySky()
        let samples = data.assumingMemoryBound(to: UInt16.self)
        let stride = sky.context.bytesPerRow / 2
        withExtendedLifetime(sky.context) {
            paintPixels(dot: dot) { column, row in
                let threshold = Self.bayer[(row % 8) * 8 + column % 8]
                let offset = row * stride + column * 4
                func level(_ channel: Int) -> Int {
                    let value = Double(samples[offset + channel]) / 65535 * 31 + threshold
                    return Int((Double(min(max(Int(value), 0), 31)) * 255 / 31).rounded())
                }
                return Tone(red: level(0), green: level(1), blue: level(2))
            }
        }
    }

    /// The sky and its clouds, smooth, in unit space.
    private mutating func paintCloudySky() {
        enterUnitSpace()
        let sky = daySky
        linear([sky.darkened(0.2), sky, sky.lightened(0.28)], from: .zero, to: CGPoint(x: 0, y: unitHeight))
        let count = Int(unitWidth * heightRatio / 170) + rng.int(below: 4)
        // Top to bottom, so nearer (higher, bigger) clouds overlap the distant ones below.
        let rows = (0 ..< count).map { _ in rng.between(40, 960) * heightRatio }.sorted(by: >)
        for row in rows {
            let depth = 1.3 - 0.6 * row / unitHeight
            let size = rng.between(0.75, 1.25) * depth
            paintCumulus(
                at: CGPoint(x: rng.between(-80, unitWidth + 80), y: row),
                width: 260 * size * rng.between(0.8, 1.5), height: 95 * size, sky: sky
            )
        }
    }

    /// One heaped cloud: puffs domed toward its middle, each painted as a blue-grey
    /// underside, a white body, and a highlight up and to the left.
    private mutating func paintCumulus(at center: CGPoint, width: CGFloat, height: CGFloat, sky: ThemeColor) {
        let puffs = (0 ..< 20 + rng.int(below: 14)).map { _ -> (center: CGPoint, radius: CGFloat) in
            let across = rng.between(-1, 1)
            let dome = 1 - across * across
            return (
                CGPoint(x: center.x + across * width / 2, y: center.y - height * dome * rng.between(0, 0.75)),
                height * (0.2 + 0.32 * dome) * rng.between(0.7, 1.15)
            )
        }
        let shade = sky.mix(.white, 0.5).darkened(0.12)
        for puff in puffs {
            self.puff(shade, at: CGPoint(x: puff.center.x, y: puff.center.y + puff.radius * 0.3), radius: puff.radius)
        }
        let body = sky.mix(.white, 0.82)
        for puff in puffs {
            let offset = CGPoint(x: puff.center.x - puff.radius * 0.08, y: puff.center.y - puff.radius * 0.06)
            self.puff(body, at: offset, radius: puff.radius * 0.85, alpha: 0.9)
        }
        for puff in puffs {
            let offset = CGPoint(x: puff.center.x - puff.radius * 0.15, y: puff.center.y - puff.radius * 0.3)
            self.puff(.white, at: offset, radius: puff.radius * 0.7, alpha: 0.45)
        }
    }

    // MARK: - Azul

    /// Windows XP's Azul: ribbons of light drifting across deep blue. Each ribbon is a fan of
    /// hairline strands that twists along its length, so the strands pinch together and
    /// glow where it turns edge-on. Strands add their light, like the original's long exposure.
    mutating func paintAzul() {
        enterUnitSpace()
        let deep = daySky
        // Darkened in HSL rather than toward black, so the blue stays rich instead of greying.
        let (hue, saturation, _) = deep.hsl
        let ground = [0.1, 0.17, 0.26].map {
            ThemeColor(hue: hue, saturation: min(1, saturation * 1.15), lightness: $0)
        }
        linear(ground, from: .zero, to: CGPoint(x: unitWidth, y: unitHeight))
        let center = CGPoint(x: unitWidth * rng.between(0.3, 0.7), y: rng.between(300, 700) * heightRatio)
        glow(deep, at: center, radius: 900, alpha: 0.35)
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let tints = [deep, palette.cyan, palette.accent].map { $0.mix(.white, 0.35) }
        for index in 0 ..< 3 + rng.int(below: 2) {
            paintRibbon(tint: tints.cycling(index))
        }
    }

    /// One twisting ribbon from edge to edge.
    private mutating func paintRibbon(tint: ThemeColor) {
        let (middle, slope) = (rng.between(250, 750) * heightRatio, rng.between(-0.3, 0.3))
        let waves = (0 ..< 2).map { _ in
            (amplitude: rng.between(50, 170), frequency: 2 * .pi / (unitWidth * rng.between(0.6, 1.5)),
             phase: rng.between(0, 2 * .pi))
        }
        let twist = (frequency: 2 * .pi / rng.between(500, 1200), phase: rng.between(0, 2 * .pi))
        let breadth = (size: rng.between(40, 110), frequency: 2 * .pi / rng.between(700, 1600), phase: rng.unit() * 6)
        let xs = Array(stride(from: -60, through: unitWidth + 60, by: 8))
        let spine = xs.map { x in
            waves.reduce(middle + slope * (x - unitWidth / 2)) { $0 + $1.amplitude * sin(x * $1.frequency + $1.phase) }
        }
        let spread = xs.map { x in
            breadth.size * (0.35 + 0.65 * pow(sin(x * breadth.frequency + breadth.phase), 2))
                * cos(x * twist.frequency + twist.phase)
        }
        let strands = 64
        context.setLineWidth(hairline(1.3))
        for strand in 0 ..< strands {
            let across = Double(strand) / Double(strands - 1) * 2 - 1
            let color = tint.mix(.white, 0.5 * (1 - abs(across)))
            context.setStrokeColor(color.cgColor(alpha: 0.05 + 0.08 * (1 - abs(across))))
            for (index, x) in xs.enumerated() {
                let point = CGPoint(x: x, y: spine[index] + across * spread[index])
                if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
    }

    // MARK: - Windows patterns

    /// Windows 3.0's desktop patterns, which Windows 95 kept, as their `win.ini` bytes: one
    /// per row, the leftmost pixel in the high bit. (50% Gray is left out; it's the Mac's
    /// checkerboard.)
    static let windowsPatterns = [
        DesktopPattern(rows: [127, 65, 65, 65, 65, 65, 127, 0]), // Boxes
        DesktopPattern(rows: [0, 80, 114, 32, 0, 5, 39, 2]), // Critters
        DesktopPattern(rows: [32, 80, 136, 80, 32, 0, 0, 0]), // Diamonds
        DesktopPattern(rows: [2, 7, 7, 2, 32, 80, 80, 32]), // Paisley
        DesktopPattern(rows: [130, 68, 40, 17, 40, 68, 130, 1]), // Quilt
        DesktopPattern(rows: [64, 192, 200, 120, 120, 72, 0, 0]), // Scottie
        DesktopPattern(rows: [20, 12, 200, 121, 158, 19, 48, 40]), // Spinner
        DesktopPattern(rows: [248, 116, 34, 71, 143, 23, 34, 113]), // Thatches
        DesktopPattern(rows: [0, 0, 84, 124, 124, 56, 146, 124]), // Tulip
        DesktopPattern(rows: [0, 0, 0, 0, 128, 128, 128, 240]), // Waffle
        DesktopPattern(rows: [136, 84, 34, 69, 136, 21, 34, 81]), // Weave
    ]

    /// A Windows pattern over the desktop color. Windows drew the set bits in black; a desktop
    /// too dark for that gets a lighter ink instead. The seed picks the pattern.
    mutating func paintWindowsPattern() {
        let desktop = classicDesktop
        let ink = desktop.relativeLuminance > 0.04 ? desktop.mix(.black, 0.9) : desktop.mix(.white, 0.3)
        let pattern = Self.windowsPatterns[rng.int(below: Self.windowsPatterns.count)]
        let tones = [Tone(desktop), Tone(ink)]
        paintPixels(dot: macPixel) { column, row in
            tones[pattern.isInk(column: column, row: row) ? 1 : 0]
        }
    }
}
