import CoreGraphics
@testable import Vibeshed
import XCTest

/// Generated wallpapers on several displays: each drawn at its own size, and the spanning
/// styles laid across the arrangement.
final class MultiDisplayWallpaperTests: XCTestCase {
    private let palette = (try? ThemePalette.resolve(BuiltInThemes.tokyoNight.colors, mode: .dark))
        ?? ThemePalette(mode: .dark, colors: [:])

    /// A landscape display with a portrait one to its left, hanging 412 points lower.
    private let layout = WallpaperLayout(displays: [
        .init(id: 1, frame: CGRect(x: 0, y: 0, width: 2250, height: 1500), backingScale: 2),
        .init(id: 2, frame: CGRect(x: -1500, y: -412, width: 1500, height: 2250), backingScale: 2),
    ])

    func testEachDisplayIsDrawnAtItsOwnSize() {
        let frames = layout.frames(spanning: false)
        XCTAssertEqual(frames[1], .single(CGSize(width: 4500, height: 3000)))
        XCTAssertEqual(frames[2], .single(CGSize(width: 3000, height: 4500)))
        // A display past 6K is drawn at 6K.
        let huge = WallpaperLayout(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 4000, height: 2000), backingScale: 2),
        ])
        XCTAssertEqual(huge.frames(spanning: true)[1]?.pixels, CGSize(width: 6144, height: 3072))
    }

    func testSpanningFramesFollowTheArrangement() throws {
        let frames = layout.frames(spanning: true)
        let landscape = try XCTUnwrap(frames[1]), portrait = try XCTUnwrap(frames[2])
        // The bounding box is 3750 × 2250 points, at 2 pixels a point.
        XCTAssertEqual(landscape.canvas, CGSize(width: 7500, height: 4500))
        XCTAssertEqual(landscape.viewport, CGRect(x: 3000, y: 824, width: 4500, height: 3000))
        XCTAssertEqual(portrait.viewport, CGRect(x: 0, y: 0, width: 3000, height: 4500))
        XCTAssertEqual(landscape.pixels, CGSize(width: 4500, height: 3000))
        XCTAssertEqual(portrait.pixels, CGSize(width: 3000, height: 4500))
        XCTAssertEqual(landscape.displays, portrait.displays)
        XCTAssertEqual(landscape.display, CGSize(width: 4500, height: 3000), "sized by the largest display")
        XCTAssertTrue(landscape.spans)
        XCTAssertNotEqual(landscape.signature, portrait.signature)
        // A single display has nothing to span.
        let alone = WallpaperLayout(displays: [layout.displays[0]])
        XCTAssertEqual(alone.frames(spanning: true)[1], .single(CGSize(width: 4500, height: 3000)))
    }

    func testMixedDensitiesShareOneCanvas() throws {
        let mixed = WallpaperLayout(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), backingScale: 2),
            .init(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), backingScale: 1),
        ])
        let frames = mixed.frames(spanning: true)
        let external = try XCTUnwrap(frames[2])
        // The canvas takes the sharper display's density; the other display scales it down.
        XCTAssertEqual(external.canvas, CGSize(width: 6864, height: 2160))
        XCTAssertEqual(external.viewport, CGRect(x: 3024, y: 0, width: 3840, height: 2160))
        XCTAssertEqual(external.pixels, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(CGPoint(x: 3024, y: 2160).applying(external.transform), CGPoint(x: 0, y: 1080))
    }

    /// Slices drawn display by display match the picture drawn whole, so the displays meet
    /// without a seam — every display makes the same seeded choices. The right display hangs
    /// lower, so the corners of the canvas aren't all on screen.
    func testSpanningSlicesMatchThePictureDrawnWhole() throws {
        let display = CGSize(width: 160, height: 100)
        let left = CGRect(origin: CGPoint(x: 0, y: 50), size: display)
        let right = CGRect(origin: CGPoint(x: 160, y: 0), size: display)
        let canvas = CGSize(width: 320, height: 150)
        let whole = WallpaperFrame(
            canvas: canvas, viewport: CGRect(origin: .zero, size: canvas), pixels: canvas, display: display,
            displays: [left, right]
        )
        for style in WallpaperStyle.allCases where style.spans {
            let choice = WallpaperChoice(style: style, seed: 3, grain: false)
            let picture = try XCTUnwrap(WallpaperRenderer.draw(palette, frame: whole, choice: choice))
            for viewport in [left, right] {
                let frame = WallpaperFrame(
                    canvas: canvas, viewport: viewport, pixels: display, display: display, displays: [left, right]
                )
                let slice = try XCTUnwrap(WallpaperRenderer.draw(palette, frame: frame, choice: choice))
                let crop = try XCTUnwrap(picture.cropping(to: CGRect(
                    x: viewport.minX, y: canvas.height - viewport.maxY, width: viewport.width, height: viewport.height
                )))
                XCTAssertLessThan(
                    mismatch(slice, crop), 0.01, "\(style.rawValue) at x \(Int(viewport.minX)) differs from the whole"
                )
            }
        }
    }

    func testPortraitDisplaysKeepALandscapeDisplaysScale() throws {
        let portrait = try XCTUnwrap(WallpaperCanvas(size: CGSize(width: 300, height: 450), palette: palette, seed: 1))
        let landscape = try XCTUnwrap(WallpaperCanvas(size: CGSize(width: 450, height: 300), palette: palette, seed: 1))
        XCTAssertEqual(portrait.unit, landscape.unit)
        XCTAssertEqual(portrait.unitHeight, 1500)
        XCTAssertEqual(landscape.heightRatio, 1)
    }

    /// The share of pixels that clearly differ. Core Graphics antialiases a stroke cut by the
    /// image's edge a little differently (up to ~20 levels along Topographic's hairlines), but a
    /// slice that made other choices differs almost everywhere.
    private func mismatch(_ first: CGImage, _ second: CGImage) -> Double {
        let (one, two) = (rgba(first), rgba(second))
        guard one.count == two.count, !one.isEmpty else { return 1 }
        var differing = 0
        for pixel in stride(from: 0, to: one.count, by: 4) {
            let close = (0 ..< 3).allSatisfy { abs(Int(one[pixel + $0]) - Int(two[pixel + $0])) <= 24 }
            if !close { differing += 1 }
        }
        return Double(differing) / Double(one.count / 4)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
