import AppKit
import XCTest
@testable import Vibeshed

/// The classic Mac bitmap wallpapers: whole-pixel, hard-edged, and unaffected by grain.
final class ClassicMacWallpaperTests: XCTestCase {
    private func colors(_ image: CGImage) -> [UInt32] {
        let data = image.dataProvider?.data.map { $0 as Data } ?? Data()
        return stride(from: 0, to: data.count, by: 4).map {
            UInt32(data[$0]) << 16 | UInt32(data[$0 + 1]) << 8 | UInt32(data[$0 + 2])
        }
    }

    private func draw(
        _ theme: ThemeDefinition, _ style: WallpaperStyle, seed: UInt64, width: Int, height: Int
    ) throws -> CGImage {
        let palette = try ThemePalette.resolve(theme.colors, mode: theme.mode ?? .light)
        let choice = WallpaperChoice(style: style, seed: seed, grain: true)
        return try XCTUnwrap(
            WallpaperRenderer.draw(palette, size: CGSize(width: width, height: height), choice: choice)
        )
    }

    func testPebblesKeepTheOriginalTileColorsAndRepeat() throws {
        let image = try draw(BuiltInThemes.system7, .pebbles, seed: 7, width: 640, height: 720)
        let painted = colors(image)
        // A desktop of exactly the tile's average color gets the tile's own 19 colors back,
        // hard-edged: the 16-bit canvas and its dithered reduction must not blur or add any.
        XCTAssertEqual(Set(painted), Set(MacintoshPebbles.palette))
        // 720 px tall is 1 device pixel per Mac pixel, so the 64-pixel tile repeats every 64.
        let width = image.width
        for (x, y) in [(5, 5), (77, 300), (300, 500)] {
            XCTAssertEqual(painted[y * width + x], painted[y * width + x + 64])
            XCTAssertEqual(painted[y * width + x], painted[(y + 64) * width + x])
        }
        // A retina-height canvas doubles the pixels: the tile then repeats every 128.
        let retina = colors(try draw(BuiltInThemes.system7, .pebbles, seed: 7, width: 640, height: 1440))
        XCTAssertEqual(retina[5 * 640 + 5], retina[5 * 640 + 5 + 128])
        XCTAssertEqual(Set(retina), Set(MacintoshPebbles.palette))
    }

    func testTileReferenceIsItsAverageColorAndSystem7UsesIt() throws {
        let palette = MacintoshPebbles.palette
        let pixels = MacintoshPebbles.indices.map { palette[Int($0)] }
        XCTAssertEqual(pixels.count, MacintoshPebbles.side * MacintoshPebbles.side)
        func average(_ shift: UInt32) -> Int {
            Int((Double(pixels.map { Int($0 >> shift & 0xFF) }.reduce(0, +)) / Double(pixels.count)).rounded())
        }
        let reference = MacintoshPebbles.reference
        XCTAssertEqual([average(16), average(8), average(0)], [reference.red, reference.green, reference.blue])
        let desktop = try XCTUnwrap(ThemePalette.resolve(BuiltInThemes.system7.colors, mode: .light)["desktop"])
        XCTAssertEqual([desktop.red8, desktop.green8, desktop.blue8], [reference.red, reference.green, reference.blue])
    }

    func testPebblesFollowTheDesktopColor() throws {
        let teal = BuiltInThemes.macOS9
        let painted = colors(try draw(teal, .pebbles, seed: 7, width: 320, height: 240))
        let desktop = try XCTUnwrap(ThemePalette.resolve(teal.colors, mode: .light)["desktop"])
        let mean = Double(painted.map { Int($0 >> 8 & 0xFF) }.reduce(0, +)) / Double(painted.count)
        // Green: the tile's average is 112 there, so the result averages near the desktop's own.
        XCTAssertEqual(mean, Double(desktop.green8), accuracy: 12)
        XCTAssertGreaterThan(Set(painted).count, 10)
    }

    func testDesktopPatternsAreTwoTones() throws {
        for seed in 0 ..< 7 {
            let image = try draw(BuiltInThemes.macOS9, .macpattern, seed: UInt64(seed), width: 240, height: 180)
            XCTAssertEqual(Set(colors(image)).count, 2, "seed \(seed)")
        }
        let patterns = WallpaperCanvas.desktopPatterns
        XCTAssertEqual(Set(patterns.map(\.rows)).count, patterns.count)
    }

    func testPinstripesAreFlatRowsThatAlternate() throws {
        let painted = colors(try draw(BuiltInThemes.macOS9, .pinstripe, seed: 3, width: 40, height: 400))
        let rows = (0 ..< 400).map { Set(painted[$0 * 40 ..< $0 * 40 + 40]) }
        XCTAssertTrue(rows.allSatisfy { $0.count == 1 }, "every row is one flat tone")
        XCTAssertGreaterThan(Set(rows.flatMap { $0 }).count, 4)
        XCTAssertTrue(zip(rows, rows.dropFirst()).contains { $0 != $1 })
    }

    func testPeriodPiecesStayOutOfAutomaticPicks() {
        let bitmaps = WallpaperStyle.allCases.filter(\.isPixelBitmap)
        XCTAssertEqual(Set(bitmaps), [.pebbles, .macpattern, .pinstripe, .clouds, .winpattern, .boing, .rain])
        let pieces = WallpaperStyle.allCases.filter(\.isPeriodPiece)
        XCTAssertEqual(Set(pieces), Set(bitmaps).union([.azul]))
        XCTAssertTrue(pieces.allSatisfy { !WallpaperStyle.varied.contains($0) })
        let optIn: Set<WallpaperStyle> = [.flow, .lens, .papercut, .automata, .chladni, .cuttingmat]
        XCTAssertTrue(optIn.allSatisfy { !WallpaperStyle.varied.contains($0) }, "styles added later are opt-in")
        XCTAssertEqual(WallpaperStyle.varied.map(\.rawValue), Self.settledPool.filter { $0 != "halftone" })
    }

    /// `auto`'s pool as it was settled, Halftone included: every theme's pick is a slot here.
    private static let settledPool = [
        "glow", "mesh", "waves", "ridges", "bokeh", "lowpoly", "topographic", "sunset", "arcs", "halftone",
        "pulsar", "guilloche", "sashiko", "attractor", "bauhaus", "destijl", "truchet", "terrazzo", "circles",
        "isometric", "penrose", "leaves", "warp", "ascii", "polyhedra", "maze", "dither", "pipes",
    ]

    func testRemovingHalftoneKeepsEveryOtherThemesAutomaticStyle() throws {
        var moved = 0
        for theme in BuiltInThemes.all {
            let slug = ResolvedTheme.slug(for: theme.name)
            let settled = Self.settledPool[Int(StableHash.of(slug) % UInt64(Self.settledPool.count))]
            let picked = try XCTUnwrap(WallpaperStyle.resolve("auto", slug: slug), theme.name)
            if settled == "halftone" {
                XCTAssertTrue(WallpaperStyle.varied.contains(picked), theme.name)
                moved += 1
            } else {
                XCTAssertEqual(picked.rawValue, settled, "\(theme.name) keeps its automatic style")
            }
        }
        XCTAssertGreaterThan(moved, 0, "some built-in theme landed on Halftone, so the re-pick is exercised")
    }
}
