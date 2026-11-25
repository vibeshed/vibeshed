import Accelerate
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Renders and caches generated wallpapers.
enum WallpaperRenderer {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vibeshed/Wallpapers", isDirectory: true)
    }

    /// Generated files kept on disk; older ones are pruned (never one that's on screen).
    private static let cacheLimit = 48

    /// Renders (or reuses) a wallpaper for every display at its own pixel size, keyed by
    /// display ID: one picture spread across the arrangement when `spanning` and the style
    /// can, else one per display. A display whose image couldn't be drawn is left out.
    /// File names carry every input, since macOS won't redraw a wallpaper whose URL didn't
    /// change. Drawn off the main thread, displays in parallel, so a live preview doesn't
    /// stall the picker.
    static func render(_ theme: ResolvedTheme, choice: WallpaperChoice, spanning: Bool) async -> [Int: URL] {
        let layout = await MainActor.run { WallpaperLayout.current }
        // Displays of the same size share an image unless it spans.
        var files: [Int: URL] = [:], jobs: [URL: WallpaperFrame] = [:]
        for (display, frame) in layout.frames(spanning: spanning && choice.style.spans) {
            let url = file(for: frame, theme: theme, choice: choice)
            files[display] = url
            jobs[url] = frame
        }
        let drawn = await withTaskGroup(of: URL?.self) { group in
            for (url, frame) in jobs {
                group.addTask { renderFile(url, frame: frame, palette: theme.palette, choice: choice) ? url : nil }
            }
            return await group.reduce(into: Set<URL>()) { drawn, url in
                if let url { drawn.insert(url) }
            }
        }
        return files.filter { drawn.contains($0.value) }
    }

    private static func file(for frame: WallpaperFrame, theme: ResolvedTheme, choice: WallpaperChoice) -> URL {
        let name = [
            theme.slug, choice.style.rawValue, String(choice.seed, radix: 16), paletteHash(theme.palette),
            "\(Int(frame.pixels.width))x\(Int(frame.pixels.height))",
        ] + (frame.spans ? ["s\(frame.signature)"] : []) + [choice.grain ? "g" : ""]
        return directory.appendingPathComponent("\(name.joined(separator: "-")).jpg")
    }

    private static func renderFile(
        _ url: URL, frame: WallpaperFrame, palette: ThemePalette, choice: WallpaperChoice
    ) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        // A superseded preview: the drawing itself can't be interrupted, so don't start it.
        guard !Task.isCancelled, let image = draw(palette, frame: frame, choice: choice) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        return writeJPEG(image, to: url)
    }

    static func draw(_ palette: ThemePalette, size: CGSize, choice: WallpaperChoice) -> CGImage? {
        draw(palette, frame: .single(size), choice: choice)
    }

    /// The part of the picture `frame` shows. Every display of a spanning picture paints the
    /// whole canvas through its own viewport (the seed makes the same choices each time), so
    /// the slices meet without having to hold the arrangement's full bitmap in memory.
    static func draw(_ palette: ThemePalette, frame: WallpaperFrame, choice: WallpaperChoice) -> CGImage? {
        guard var canvas = WallpaperCanvas(frame: frame, palette: palette, seed: choice.seed) else { return nil }
        // Styles may change the transform (unit space) or blend mode; grain goes on untouched,
        // in the image's own pixels.
        canvas.context.saveGState()
        canvas.context.concatenate(canvas.canvasToPixels)
        painters[choice.style]?(&canvas)
        canvas.context.restoreGState()
        if choice.grain, !choice.style.isPixelBitmap { canvas.addGrain() }
        return canvas.ditheredImage()
    }

    private static let painters: [WallpaperStyle: @Sendable (inout WallpaperCanvas) -> Void] = [
        .glow: { $0.paintGlow() }, .mesh: { $0.paintMesh() }, .waves: { $0.paintWaves() },
        .ridges: { $0.paintRidges() }, .bokeh: { $0.paintBokeh() }, .lowpoly: { $0.paintLowPoly() },
        .topographic: { $0.paintTopographic() }, .sunset: { $0.paintSunset() }, .arcs: { $0.paintArcs() },
        .pulsar: { $0.paintPulsar() }, .guilloche: { $0.paintGuilloche() },
        .sashiko: { $0.paintSashiko() }, .attractor: { $0.paintAttractor() }, .bauhaus: { $0.paintBauhaus() },
        .destijl: { $0.paintDeStijl() }, .truchet: { $0.paintTruchet() }, .terrazzo: { $0.paintTerrazzo() },
        .circles: { $0.paintCircles() }, .isometric: { $0.paintIsometric() }, .penrose: { $0.paintPenrose() },
        .flow: { $0.paintFlow() }, .lens: { $0.paintLens() }, .papercut: { $0.paintPaperCut() },
        .automata: { $0.paintAutomata() }, .chladni: { $0.paintChladni() }, .cuttingmat: { $0.paintCuttingMat() },
        .leaves: { $0.paintLeaves() }, .warp: { $0.paintWarp() }, .ascii: { $0.paintASCII() },
        .polyhedra: { $0.paintPolyhedra() }, .maze: { $0.paintMaze() }, .dither: { $0.paintDither() },
        .pipes: { $0.paintPipes() }, .pebbles: { $0.paintPebbles() }, .macpattern: { $0.paintDesktopPattern() },
        .pinstripe: { $0.paintPinstripes() }, .clouds: { $0.paintClouds() }, .azul: { $0.paintAzul() },
        .winpattern: { $0.paintWindowsPattern() }, .boing: { $0.paintBoing() }, .rain: { $0.paintRain() },
        .solid: { $0.fill($0.palette.background) },
    ]

    /// Whether any display shows a generated wallpaper.
    @MainActor
    static func isOnScreen() -> Bool {
        let folder = directory.standardizedFileURL.path + "/"
        return NSScreen.screens.contains {
            NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path.hasPrefix(folder) == true
        }
    }

    /// Deletes all but the most recent generated wallpapers, sparing any on screen.
    @MainActor
    static func prune() {
        let inUse = Set(NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL
        })
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        let byAge = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for file in byAge.dropFirst(cacheLimit) where !inUse.contains(file.standardizedFileURL) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Helpers

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination)
    }

    private static func paletteHash(_ palette: ThemePalette) -> String {
        let seed = palette.colors.keys.sorted().compactMap { palette[$0]?.hexStripped }.joined()
        return String(StableHash.of(seed) & 0xFFFF_FFFF, radix: 16)
    }
}

/// A bitmap plus the palette-derived tones and seeded randomness every style draws with.
/// Coordinates are Core Graphics' (origin bottom-left) over the whole canvas, which for a
/// spanning picture is the display arrangement and larger than the bitmap; sizes scale with
/// `unit`. Painted at 16 bits per channel and dithered down to 8, so wide soft gradients
/// don't band into visible rings.
struct WallpaperCanvas {
    let context: CGContext
    let rect: CGRect
    let palette: ThemePalette
    let space: CGColorSpace
    let noise: ValueNoise
    var rng: SeededGenerator
    /// One thousandth of a display's shorter side: keeps line widths and radii
    /// resolution-independent, and the same size on a portrait display as on a landscape one.
    let unit: CGFloat
    /// One display's worth of the canvas (`WallpaperFrame.display`).
    let display: CGSize
    /// Where the displays are on the canvas: just `rect` unless spanning.
    let displays: [CGRect]
    /// `WallpaperFrame.transform`, under every style's own.
    let canvasToPixels: CGAffineTransform

    init?(size: CGSize, palette: ThemePalette, seed: UInt64) {
        self.init(frame: .single(size), palette: palette, seed: seed)
    }

    /// The bitmap is `frame.pixels`; drawing in canvas coordinates needs `frame.transform`,
    /// which `WallpaperRenderer.draw` sets up.
    init?(frame: WallpaperFrame, palette: ThemePalette, seed: UInt64) {
        guard frame.pixels.width >= 1, frame.pixels.height >= 1, frame.display.width >= 1, frame.display.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int(frame.pixels.width), height: Int(frame.pixels.height), bitsPerComponent: 16,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        self.context = context
        self.rect = CGRect(origin: .zero, size: frame.canvas)
        self.palette = palette
        self.space = space
        self.noise = ValueNoise(seed: seed ^ 0xA5A5_5A5A_1234_4321)
        self.rng = SeededGenerator(seed: seed)
        self.unit = min(frame.display.width, frame.display.height) / 1000
        self.display = frame.display
        self.displays = frame.displays
        self.canvasToPixels = frame.transform
    }

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var isDark: Bool { palette.mode == .dark }

    /// How many displays' worth of canvas there is across and down (1 × 1 unless spanning),
    /// for styles that scatter a set number of things or fit a set number of cells.
    var spread: CGSize { CGSize(width: width / display.width, height: height / display.height) }
    /// Display areas the canvas holds: what a count tuned for one screen is multiplied by.
    var spreadArea: CGFloat { spread.width * spread.height }

    /// Whether any display shows `point` (in the current user space, so unit space works).
    func isShown(_ point: CGPoint) -> Bool {
        // Through the CTM, not `convertToDeviceSpace`: a bitmap's device space is flipped.
        let onCanvas = point.applying(context.ctm).applying(canvasToPixels.inverted())
        return displays.contains { $0.contains(onCanvas) }
    }

    /// The deepest tone (dark themes) or the page itself (light themes).
    var base: ThemeColor { isDark ? palette.darkerBackground : palette.background }
    var surface: ThemeColor { isDark ? palette.background : palette.darkBackground }

    /// The accent and the palette hues closest to it — colors that sit well together.
    /// `keepingTwin` keeps a hue that is the accent's own color (most themes set the accent
    /// to one of their hues), right after it, so the set leans harder on the accent.
    func harmony(_ count: Int, keepingTwin: Bool = false) -> [ThemeColor] {
        let accentHue = palette.accent.hsl.hue
        let hues = [palette.red, palette.orange, palette.yellow, palette.green, palette.cyan, palette.blue]
            + [palette.magenta]
        return Array(([palette.accent] + hues
            .filter { (keepingTwin || $0 != palette.accent) && $0.hsl.saturation > 0.12 }
            .sorted { ThemeColor.hueDistance($0.hsl.hue, accentHue) < ThemeColor.hueDistance($1.hsl.hue, accentHue) })
            .prefix(count))
    }

    /// A palette color toned toward the background so large areas don't shout.
    func muted(_ color: ThemeColor, _ amount: Double) -> ThemeColor {
        color.mix(base, amount)
    }

    // MARK: - Primitives

    /// Covers the whole canvas, in whatever coordinate space is current.
    func fill(_ color: ThemeColor) {
        context.setFillColor(color.cgColor)
        context.fill(context.boundingBoxOfClipPath)
    }

    func linear(_ colors: [ThemeColor], from start: CGPoint, to end: CGPoint) {
        guard let gradient = CGGradient(
            colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil
        ) else { return }
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        context.drawLinearGradient(gradient, start: start, end: end, options: extend)
    }

    func glow(_ color: ThemeColor, at center: CGPoint, radius: CGFloat, alpha: Double) {
        let inner = color.cgColor.copy(alpha: alpha) ?? color.cgColor
        let outer = color.cgColor.copy(alpha: 0) ?? color.cgColor
        guard let gradient = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1])
        else { return }
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
        )
    }

    func disc(at center: CGPoint, radius: CGFloat) {
        let diameter = radius * 2
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter))
    }

    /// Point at fractional coordinates of the canvas.
    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: width * x, y: height * y)
    }

    /// The canvas reduced to 8 bits per channel with ordered dithering (every 16-bit
    /// sample converted independently, so the interleaved RGBA rows are one plane).
    func ditheredImage() -> CGImage? {
        guard let data = context.data else { return nil }
        let samplesPerRow = context.width * 4
        let rowBytes = samplesPerRow
        guard let output = malloc(rowBytes * context.height) else { return nil }
        var source = vImage_Buffer(
            data: data, height: vImagePixelCount(context.height), width: vImagePixelCount(samplesPerRow),
            rowBytes: context.bytesPerRow
        )
        var destination = vImage_Buffer(
            data: output, height: vImagePixelCount(context.height), width: vImagePixelCount(samplesPerRow),
            rowBytes: rowBytes
        )
        let status = vImageConvert_Planar16UtoPlanar8_dithered(
            &source, &destination, Int32(kvImageConvert_DitherOrderedReproducible), vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError,
              let provider = CGDataProvider(
                  dataInfo: nil, data: output, size: rowBytes * context.height,
                  releaseData: { _, pointer, _ in free(UnsafeMutableRawPointer(mutating: pointer)) }
              )
        else {
            free(output)
            return nil
        }
        return CGImage(
            width: context.width, height: context.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Faint monochrome film grain, tiled — texture on top of the dithered gradients.
    mutating func addGrain() {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0 ..< side * side {
            let alpha = UInt8(rng.between(0, isDark ? 9 : 7))
            let value: UInt8 = rng.unit() < 0.5 ? 0 : alpha // premultiplied white or black
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let tile = CGImage(
                  width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return }
        context.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
    }
}
