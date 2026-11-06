import CoreGraphics
import Foundation

/// Derives a complete palette from an image, in the spirit of Aether: a background and
/// foreground tinted by the image's dominant tone, its most vivid color as the accent,
/// and each ANSI hue pulled toward whatever the image actually has near that hue — so
/// the terminal, editor and system accents all feel like they belong to the wallpaper.
enum ThemeGenerator {
    static let generatedName = "Last from Wallpaper"

    /// Target hue (degrees) for each semantic color.
    private static let hueTargets: [(key: String, hue: Double)] = [
        ("red", 355), ("orange", 25), ("yellow", 45), ("green", 115),
        ("cyan", 180), ("blue", 218), ("magenta", 295),
    ]

    private struct Sample {
        let hue: Double
        let saturation: Double
        let lightness: Double
    }

    /// The palette for the wallpaper file at `url` as it looks in the current appearance. A
    /// dynamic desktop's light/dark picture follows the appearance, so the theme keeps it
    /// too (applying it won't flip the system and swap the picture it came from).
    static func palette(fromWallpaper url: URL, dark: Bool) -> [String: String]? {
        guard let wallpaper = DynamicDesktop.thumbnail(of: url, dark: dark, maxPixelSize: 512) else { return nil }
        let mode: ThemeMode? = wallpaper.followsAppearance ? (dark ? .dark : .light) : nil
        return palette(from: wallpaper.image, mode: mode)
    }

    /// Returns raw `colors.toml`-style keys (hex values plus `mode`), or nil if the image
    /// can't be read.
    static func palette(from image: CGImage, mode requestedMode: ThemeMode? = nil) -> [String: String]? {
        guard let samples = sample(image), !samples.isEmpty else { return nil }

        let averageLightness = samples.map(\.lightness).reduce(0, +) / Double(samples.count)
        let mode = requestedMode ?? (averageLightness > 0.62 ? .light : .dark)
        let isDark = mode == .dark

        let saturations = samples.map(\.saturation).sorted()
        let vibrancy = saturations[Int(Double(saturations.count - 1) * 0.75)]
        let hueSaturation = min(max(vibrancy, 0.45), 0.78)
        let hueLightness = isDark ? 0.68 : 0.42

        // Background: the image's darkest (dark mode) or lightest (light mode) tone.
        let byLightness = samples.sorted { $0.lightness < $1.lightness }
        let toneSlice = isDark ? byLightness.prefix(byLightness.count / 3) : byLightness.suffix(byLightness.count / 3)
        let toneHue = circularMeanHue(Array(toneSlice), weightedBySaturation: true) ?? 230
        let toneSaturation = min((toneSlice.map(\.saturation).reduce(0, +) / Double(max(toneSlice.count, 1))), 0.35)

        let background = ThemeColor(hue: toneHue, saturation: toneSaturation * 0.6, lightness: isDark ? 0.1 : 0.95)
        let foreground = ThemeColor(hue: toneHue, saturation: 0.18, lightness: isDark ? 0.86 : 0.2)
        let accentLightness = isDark ? 0.66 : 0.45
        let accent = mostVivid(samples, near: accentLightness).map {
            ThemeColor(hue: $0.hue, saturation: max($0.saturation, 0.5), lightness: accentLightness)
        } ?? ThemeColor(hue: 218, saturation: hueSaturation, lightness: hueLightness)

        var colors: [String: ThemeColor] = [
            "background": background,
            "foreground": foreground,
            "bright_foreground": ThemeColor(hue: toneHue, saturation: 0.12, lightness: isDark ? 0.94 : 0.1),
            "accent": accent,
            "muted": ThemeColor(hue: toneHue, saturation: 0.12, lightness: isDark ? 0.45 : 0.55),
            "selection_background": background.mix(accent, 0.3),
            "lighter_background": background.mix(foreground, 0.08),
        ]
        let vivid = samples.filter { $0.saturation > 0.25 && $0.lightness > 0.15 && $0.lightness < 0.9 }
        let vividByTarget = Dictionary(grouping: vivid) { nearestTarget(to: $0.hue) }
        for target in hueTargets {
            let hue = nearbyHue(target.hue, in: vividByTarget[target.key] ?? [], of: samples.count) ?? target.hue
            colors[target.key] = ThemeColor(hue: hue, saturation: hueSaturation, lightness: hueLightness)
            colors["bright_\(target.key)"] = ThemeColor(
                hue: hue,
                saturation: min(hueSaturation + 0.05, 1),
                lightness: hueLightness + (isDark ? 0.08 : -0.06)
            )
        }

        var raw = colors.mapValues(\.hex)
        raw["mode"] = mode.rawValue
        return raw
    }

    // MARK: - System settings

    /// The System Settings that suit the wallpaper at `url` as it looks in the current
    /// appearance (see `macStyle(from:)`).
    static func macStyle(fromWallpaper url: URL, dark: Bool) -> MacStyle? {
        DynamicDesktop.thumbnail(of: url, dark: dark, maxPixelSize: 512).flatMap { macStyle(from: $0.image) }
    }

    /// System Settings that suit the picture:
    /// - a menu bar background when the strip under the menu bar is busy enough to fight
    ///   its text: light and dark parts side by side, or fine texture;
    /// - Liquid Glass tinted in step with how busy the whole picture is, so calm gradients
    ///   keep clear glass and photos get enough tint to read over;
    /// - icons tinted (in the accent, through the folder color) when the picture is
    ///   essentially one vivid hue; otherwise your own icon style.
    /// Thresholds come from macOS's own wallpapers: hello, Sonoma or Monterey leave a calm
    /// strip and clear glass, while Motion, Grid, Catalina Rock or Big Sur Waters Edge get
    /// a background and the most tint; the iMac and dark hello pictures read as one hue.
    static func macStyle(from image: CGImage) -> MacStyle? {
        guard let samples = sample(image) else { return nil }
        let size = sampleSize
        let lightness = samples.map(\.lightness)

        let texture = meanStep(lightness, width: size, rows: 0 ..< size, vertical: true)
        let stripRows = 0 ..< 4 // ~4% of the height, top first
        let strip = Array(lightness[0 ..< stripRows.count * size])
        let stripTexture = meanStep(lightness, width: size, rows: stripRows, vertical: false)
        let stripBusy = standardDeviation(strip) >= 0.15 || stripTexture >= 0.04

        let tint = min(max((texture - 0.01) / 0.05, 0), 1) * 0.75
        let vivid = samples.filter { $0.saturation > 0.25 && $0.lightness > 0.15 && $0.lightness < 0.9 }
        let oneHue = Double(vivid.count) >= Double(samples.count) * 0.5 && hueConcentration(vivid) >= 0.97
        return MacStyle(
            glass: (tint * 20).rounded() / 20,
            iconStyle: oneHue ? IconStyle(.tinted) : nil,
            menuBarBackground: stripBusy ? .show : .hide
        )
    }

    /// The mean lightness step between neighbouring samples in `rows` (row-major, top
    /// first): about 0.01 for a smooth gradient, 0.06 and up for streaks or a rocky photo.
    private static func meanStep(_ lightness: [Double], width: Int, rows: Range<Int>, vertical: Bool) -> Double {
        var total = 0.0
        var count = 0
        for row in rows {
            for column in 0 ..< width {
                let index = row * width + column
                if column + 1 < width {
                    total += abs(lightness[index] - lightness[index + 1])
                    count += 1
                }
                if vertical, row + 1 < rows.upperBound {
                    total += abs(lightness[index] - lightness[index + width])
                    count += 1
                }
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    /// How tightly the samples' hues gather, weighted by saturation: 1 is a single hue.
    private static func hueConcentration(_ samples: [Sample]) -> Double {
        var sinSum = 0.0
        var cosSum = 0.0
        var weight = 0.0
        for sample in samples {
            let radians = sample.hue * .pi / 180
            sinSum += sin(radians) * sample.saturation
            cosSum += cos(radians) * sample.saturation
            weight += sample.saturation
        }
        return weight > 0 ? (sinSum * sinSum + cosSum * cosSum).squareRoot() / weight : 0
    }

    // MARK: - Sampling

    /// Fine enough that thin highlights (a glow's rim) survive the downsampling.
    private static let sampleSize = 96

    private static func sample(_ image: CGImage) -> [Sample]? {
        let size = sampleSize
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        return (0 ..< size * size).map { index in
            let offset = index * 4
            let color = ThemeColor(
                red: Double(bytes[offset]) / 255,
                green: Double(bytes[offset + 1]) / 255,
                blue: Double(bytes[offset + 2]) / 255
            )
            let hsl = color.hsl
            return Sample(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness)
        }
    }

    /// The most saturated sample near `lightness`, the lightness it will be shown at, so it
    /// keeps its character: a glow's orange rim rather than the red it fades into, which
    /// turns salmon when lightened. Very dark/light pixels are skipped (unreliable hue).
    private static func mostVivid(_ samples: [Sample], near lightness: Double) -> Sample? {
        func score(_ sample: Sample) -> Double {
            sample.saturation * (1 - abs(sample.lightness - lightness) * 1.2)
        }
        return samples
            .filter { $0.lightness > 0.2 && $0.lightness < 0.85 }
            .max { score($0) < score($1) }
            .flatMap { score($0) > 0.2 ? $0 : nil }
    }

    /// The semantic hue nearest `hue`, so each image color informs one ANSI slot only.
    private static func nearestTarget(to hue: Double) -> String {
        hueTargets.min { ThemeColor.hueDistance(hue, $0.hue) < ThemeColor.hueDistance(hue, $1.hue) }?.key ?? ""
    }

    /// The image's own hue near `target` (±28°) among the colors closest to it, if there's
    /// enough of it (1% of `total` samples) — an orange glow tints `orange` without also
    /// dragging `yellow` toward it. Pulled halfway toward the target so red stays red.
    private static func nearbyHue(_ target: Double, in candidates: [Sample], of total: Int) -> Double? {
        let nearby = candidates.filter { ThemeColor.hueDistance($0.hue, target) <= 28 }
        guard nearby.count >= total / 100 + 1,
              let mean = circularMeanHue(nearby, weightedBySaturation: true)
        else { return nil }
        return circularMean([(mean, 1), (target, 1)])
    }

    private static func circularMeanHue(_ samples: [Sample], weightedBySaturation: Bool) -> Double? {
        circularMean(samples.map { ($0.hue, weightedBySaturation ? $0.saturation : 1) })
    }

    private static func circularMean(_ values: [(hue: Double, weight: Double)]) -> Double? {
        var sinSum = 0.0
        var cosSum = 0.0
        for value in values {
            let radians = value.hue * .pi / 180
            sinSum += sin(radians) * value.weight
            cosSum += cos(radians) * value.weight
        }
        guard abs(sinSum) + abs(cosSum) > 0.000_1 else { return nil }
        let degrees = atan2(sinSum, cosSum) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
