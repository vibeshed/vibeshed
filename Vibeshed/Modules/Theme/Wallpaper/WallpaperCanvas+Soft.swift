import CoreGraphics
import Foundation

/// A smooth color field: palette colors pinned at random points, blended by inverse
/// distance. Shared by the mesh and low-poly styles. Points are at fractions of the canvas;
/// `scale` turns those into display heights, the distance the blend is tuned for.
struct MeshField {
    let points: [(x: Double, y: Double, color: ThemeColor)]
    let scale: (x: Double, y: Double)

    func color(at x: Double, _ y: Double) -> ThemeColor {
        var weights = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for point in points {
            let dx = (x - point.x) * scale.x
            let dy = (y - point.y) * scale.y
            let weight = 1 / pow(dx * dx + dy * dy + 0.015, 1.7)
            weights += weight
            red += point.color.red * weight
            green += point.color.green * weight
            blue += point.color.blue * weight
        }
        return ThemeColor(red: red / weights, green: green / weights, blue: blue / weights)
    }
}

extension WallpaperCanvas {
    // MARK: - Glow

    /// A diagonal wash from the deepest tone into the background, lit by soft glows.
    mutating func paintGlow() {
        let wash = isDark ? palette.background : palette.lighterBackground
        linear([base, wash], from: point(0, 1), to: point(1, 0))
        let strength = isDark ? 0.35 : 0.22
        let radius = max(width, height) * 0.75
        glow(palette.accent, at: point(rng.between(0.7, 0.9), rng.between(0.1, 0.3)), radius: radius, alpha: strength)
        glow(palette.magenta, at: point(rng.between(0.05, 0.25), rng.between(0.75, 0.95)),
             radius: radius * 0.8, alpha: strength * 0.6)
        glow(palette.cyan, at: point(rng.between(0.35, 0.55), rng.between(0.45, 0.65)),
             radius: radius * 0.5, alpha: strength * 0.25)
    }

    // MARK: - Mesh

    mutating func meshField() -> MeshField {
        let tones = harmony(3)
        let colors = [
            base, surface,
            muted(tones[0], isDark ? 0.35 : 0.3),
            muted(tones.count > 1 ? tones[1] : palette.magenta, isDark ? 0.5 : 0.45),
            muted(tones.count > 2 ? tones[2] : palette.cyan, isDark ? 0.6 : 0.5),
        ]
        // A set of colors per display's worth of canvas, so a spanning field isn't one screen's
        // blend stretched across all of them.
        let sets = max(1, Int(spreadArea.rounded()))
        let points = (0 ..< sets * colors.count).map { index in
            (x: rng.between(-0.1, 1.1), y: rng.between(-0.1, 1.1), color: colors[index % colors.count])
        }
        let displayHeight = Double(display.height)
        return MeshField(points: points, scale: (Double(width) / displayHeight, Double(height) / displayHeight))
    }

    /// Computed at low resolution and scaled up — the field is smooth, so nothing is lost.
    mutating func paintMesh() {
        let field = meshField()
        let columns = Int((160 * spread.width).rounded())
        let rows = max(1, Int(Double(columns) * Double(height / width)))
        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let color = field.color(at: Double(column) / Double(columns - 1), Double(row) / Double(rows - 1))
                let offset = ((rows - 1 - row) * columns + column) * 4
                pixels[offset] = UInt8(color.red8)
                pixels[offset + 1] = UInt8(color.green8)
                pixels[offset + 2] = UInt8(color.blue8)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return fill(base) }
        context.draw(image, in: rect)
    }

    // MARK: - Waves

    mutating func paintWaves() {
        linear(isDark ? [base, surface] : [surface, base], from: point(0, 1), to: point(0, 0))
        let tones = harmony(3)
        let layers = 6
        for layer in 0 ..< layers {
            let depth = Double(layer) / Double(layers - 1) // 0 = back, 1 = front
            let baseline = height * (0.7 - 0.5 * depth)
            let amplitude = unit * rng.between(28, 55)
            let frequency = rng.between(0.7, 1.5) * spread.width
            let phase = rng.between(0, .pi * 2)
            let ripple = rng.between(0, .pi * 2)
            let color = muted(tones[layer % tones.count], isDark ? 0.84 - 0.34 * depth : 0.8 - 0.32 * depth)

            let path = CGMutablePath()
            path.move(to: .zero)
            let steps = Int((120 * spread.width).rounded())
            for step in 0 ... steps {
                let x = Double(step) / Double(steps)
                let y = baseline + amplitude * sin(2 * .pi * frequency * x + phase)
                    + amplitude * 0.35 * sin(2 * .pi * frequency * 2.3 * x + ripple)
                path.addLine(to: CGPoint(x: width * x, y: y))
            }
            path.addLine(to: CGPoint(x: width, y: 0))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color.cgColor.copy(alpha: 0.92) ?? color.cgColor)
            context.fillPath()
        }
    }

    // MARK: - Ridges

    mutating func paintRidges() {
        let horizon = palette.accent.mix(surface, isDark ? 0.72 : 0.78)
        linear([base, horizon], from: point(0, 1), to: point(0, 0.3))

        let sun = point(rng.between(0.25, 0.75), rng.between(0.58, 0.7))
        let sunColor = palette.accent.mix(palette.foreground, 0.15)
        glow(sunColor, at: sun, radius: height * 0.5, alpha: isDark ? 0.28 : 0.2)
        context.setFillColor(sunColor.cgColor.copy(alpha: 0.9) ?? sunColor.cgColor)
        disc(at: sun, radius: unit * 70)

        let tint = harmony(2).last ?? palette.accent
        let near = isDark ? palette.darkerBackground.mix(tint, 0.15) : palette.muted.mix(tint, 0.25)
        let layers = 5
        for layer in 0 ..< layers {
            let depth = Double(layer) / Double(layers - 1)
            let color = near.mix(horizon, (1 - depth) * 0.75)
            let baseline = Double(height) * (0.55 - 0.17 * depth)
            let roughness = 0.24 * (1 - 0.35 * depth)
            let path = CGMutablePath()
            path.move(to: .zero)
            let steps = 220
            for step in 0 ... steps {
                let x = Double(step) / Double(steps)
                let ridge = noise.fractal(x * 3.2 + Double(layer) * 7.3, Double(layer) * 3.1, octaves: 5)
                path.addLine(to: CGPoint(x: width * x, y: baseline + (ridge - 0.5) * Double(height) * roughness))
            }
            path.addLine(to: CGPoint(x: width, y: 0))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
    }

    // MARK: - Bokeh

    mutating func paintBokeh() {
        linear([base, surface], from: point(0, 1), to: point(1, 0))
        glow(palette.accent, at: point(0.7, 0.35), radius: max(width, height) * 0.6, alpha: isDark ? 0.18 : 0.1)
        context.setBlendMode(isDark ? .screen : .multiply)
        let tones = harmony(4)
        for _ in 0 ..< 60 {
            // Mostly small discs, a few large ones.
            let radius = unit * (18 + 150 * pow(rng.unit(), 2.2))
            let center = point(rng.unit(), rng.unit())
            let color = tones[Int(rng.between(0, Double(tones.count)))]
            let alpha = rng.between(isDark ? 0.07 : 0.05, isDark ? 0.3 : 0.18)
            let stops = [color.cgColor.copy(alpha: alpha), color.cgColor.copy(alpha: alpha * 0.85),
                         color.cgColor.copy(alpha: alpha * 0.45), color.cgColor.copy(alpha: 0)].compactMap { $0 }
            guard let gradient = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: [0, 0.7, 0.93, 1])
            else { continue }
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
            )
        }
        context.setBlendMode(.normal)
    }

    // MARK: - Low poly

    mutating func paintLowPoly() {
        let field = meshField()
        let columns = Int((18 * spread.width).rounded())
        let rows = max(2, Int((Double(columns) * Double(height / width)).rounded()))
        var grid: [[CGPoint]] = []
        for row in 0 ... rows {
            var line: [CGPoint] = []
            for column in 0 ... columns {
                let edgeX = column == 0 || column == columns
                let edgeY = row == 0 || row == rows
                let x = (Double(column) + (edgeX ? 0 : rng.between(-0.38, 0.38))) / Double(columns)
                let y = (Double(row) + (edgeY ? 0 : rng.between(-0.38, 0.38))) / Double(rows)
                line.append(point(x, y))
            }
            grid.append(line)
        }
        context.setLineJoin(.round)
        context.setLineWidth(unit * 0.8) // same-color stroke hides hairline seams
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let topLeft = grid[row + 1][column], topRight = grid[row + 1][column + 1]
                let bottomLeft = grid[row][column], bottomRight = grid[row][column + 1]
                let triangles = rng.unit() < 0.5
                    ? [[bottomLeft, topLeft, topRight], [bottomLeft, topRight, bottomRight]]
                    : [[bottomLeft, topLeft, bottomRight], [topLeft, topRight, bottomRight]]
                for triangle in triangles {
                    let cx = triangle.map(\.x).reduce(0, +) / 3 / width
                    let cy = triangle.map(\.y).reduce(0, +) / 3 / height
                    let shade = rng.between(-0.05, 0.05)
                    let base = field.color(at: Double(cx), Double(cy))
                    let color = shade > 0 ? base.lightened(shade) : base.darkened(-shade)
                    context.addLines(between: triangle)
                    context.closePath()
                    context.setFillColor(color.cgColor)
                    context.setStrokeColor(color.cgColor)
                    context.drawPath(using: .fillStroke)
                }
            }
        }
    }
}
