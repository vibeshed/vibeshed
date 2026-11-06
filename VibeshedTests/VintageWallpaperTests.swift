import AppKit
import XCTest
@testable import Vibeshed

/// The Windows, Amiga and QNX themes and their wallpapers: hard-edged pixels held to each
/// system's color depth.
final class VintageWallpaperTests: XCTestCase {
    private func colors(_ image: CGImage) -> [UInt32] {
        let data = image.dataProvider?.data.map { $0 as Data } ?? Data()
        return stride(from: 0, to: data.count, by: 4).map {
            UInt32(data[$0]) << 16 | UInt32(data[$0 + 1]) << 8 | UInt32(data[$0 + 2])
        }
    }

    private func draw(
        _ theme: ThemeDefinition, _ style: WallpaperStyle, seed: UInt64 = 3, width: Int = 480, height: Int = 270
    ) throws -> [UInt32] {
        let palette = try ThemePalette.resolve(theme.colors, mode: theme.mode ?? .light)
        let choice = WallpaperChoice(style: style, seed: seed, grain: true)
        return try colors(XCTUnwrap(
            WallpaperRenderer.draw(palette, size: CGSize(width: width, height: height), choice: choice)
        ))
    }

    private func channels(_ color: UInt32) -> [Int] {
        [Int(color >> 16 & 0xFF), Int(color >> 8 & 0xFF), Int(color & 0xFF)]
    }

    func testThemesDefaultToTheirOwnWallpapers() {
        let styles = BuiltInThemes.vintage.map { $0.wallpaperStyle.flatMap(WallpaperStyle.init(rawValue:)) }
        XCTAssertEqual(styles, [.clouds, .azul, .boing, .boing, .rain])
        for theme in BuiltInThemes.vintage {
            XCTAssertNoThrow(try ThemePalette.resolve(theme.colors, mode: theme.mode), theme.name)
            // Listed as shipped: with the macOS settings classic desktops get (menu bar
            // background, tinted glass).
            XCTAssertTrue(BuiltInThemes.all.contains(BuiltInThemes.withMacStyle(theme)), theme.name)
            XCTAssertFalse(BuiltInThemes.macStyles[theme.name]?.isEmpty ?? true, theme.name)
        }
    }

    func testAmigaThemesStayInTheTwelveBitPalette() {
        for theme in [BuiltInThemes.workbench13, BuiltInThemes.workbench31] {
            for (key, hex) in theme.colors {
                let color = ThemeColor(hex: hex)
                XCTAssertTrue(
                    [color?.red8, color?.green8, color?.blue8].allSatisfy { ($0 ?? 1) % 17 == 0 },
                    "\(theme.name) \(key) \(hex)"
                )
            }
        }
    }

    func testBoingIsTwelveBitAndHardEdged() throws {
        for theme in [BuiltInThemes.workbench13, BuiltInThemes.windowsXP] {
            let painted = Set(try draw(theme, .boing))
            XCTAssertTrue(painted.allSatisfy { channels($0).allSatisfy { $0 % 17 == 0 } }, theme.name)
            // Wall, grid, red, white, and the wall and grid in shadow.
            XCTAssertEqual(painted.count, 6, theme.name)
        }
    }

    func testCloudsAreFifteenBitColor() throws {
        let levels = Set((0 ... 31).map { Int((Double($0) * 255 / 31).rounded()) })
        let painted = Set(try draw(BuiltInThemes.windows95, .clouds))
        XCTAssertTrue(painted.allSatisfy { channels($0).allSatisfy(levels.contains) })
        XCTAssertGreaterThan(painted.count, 20, "a sky and clouds, not a flat fill")
    }

    func testWindowsPatternsAreTwoTonesOverTheDesktop() throws {
        for seed in 0 ..< UInt64(WallpaperCanvas.windowsPatterns.count) {
            let painted = try draw(BuiltInThemes.windows95, .winpattern, seed: seed, width: 240, height: 180)
            XCTAssertEqual(Set(painted).count, 2, "seed \(seed)")
            XCTAssertTrue(painted.contains(0x008080), "the teal desktop shows through")
        }
        let patterns = WallpaperCanvas.windowsPatterns
        XCTAssertEqual(Set(patterns.map(\.rows)).count, patterns.count)
        XCTAssertTrue(patterns.allSatisfy { $0.rows.count == 8 })
    }

    func testRainIsGlyphsOnTheDesktop() throws {
        let painted = try draw(BuiltInThemes.qnxPhoton, .rain)
        let counts = Dictionary(painted.map { ($0, 1) }, uniquingKeysWith: +)
        XCTAssertLessThanOrEqual(counts.count, 8, "the ground, six trail tones and the head")
        XCTAssertEqual(counts.max { $0.value < $1.value }?.key, 0x7979A7, "mostly desktop")
        XCTAssertTrue(counts.keys.contains(0xFFFFFF), "white heads on a light desktop")
        XCTAssertTrue(WallpaperCanvas.rainGlyphs.allSatisfy { $0.count == 7 && $0.allSatisfy { $0 < 32 } })
    }

    func testAzulIsBlueWithBrightRibbons() throws {
        let painted = try draw(BuiltInThemes.windowsXP, .azul).map(channels)
        XCTAssertTrue(painted.allSatisfy { $0[2] >= $0[0] }, "blue throughout")
        let lightness = painted.map { $0.reduce(0, +) / 3 }.sorted()
        XCTAssertGreaterThan(lightness[lightness.count * 99 / 100] - lightness[lightness.count / 2], 60, "ribbons glow")
    }
}
