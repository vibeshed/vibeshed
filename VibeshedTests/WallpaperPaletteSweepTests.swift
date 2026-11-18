import XCTest
@testable import Vibeshed

/// Generated wallpaper styles drawn with palettes they might not expect. A painter runs inside
/// the app, so an out-of-range index on some palette takes Vibeshed down mid-preview (a
/// grayscale theme left the ASCII Mandelbrot one `harmony` tone short).
final class WallpaperPaletteSweepTests: XCTestCase {
    private let size = CGSize(width: 160, height: 100)

    /// No hue saturated enough for `harmony`, so it gives back the accent alone.
    private static func gray(_ mode: ThemeMode) throws -> ThemePalette {
        let (background, foreground, accent) = mode == .dark
            ? ("#111111", "#dddddd", "#888888")
            : ("#f4f4f4", "#222222", "#666666")
        var colors = ["background": background, "foreground": foreground, "accent": accent]
        for key in ThemePalette.requiredHueKeys + ["orange"] {
            colors[key] = accent
        }
        return try ThemePalette.resolve(colors, mode: mode)
    }

    private func drawEveryStyle(_ palette: ThemePalette, seeds: [UInt64], _ label: String) {
        for style in WallpaperStyle.allCases {
            for seed in seeds {
                let choice = WallpaperChoice(style: style, seed: seed, grain: false)
                XCTAssertNotNil(
                    WallpaperRenderer.draw(palette, size: size, choice: choice), "\(label) \(style) \(seed)"
                )
            }
        }
    }

    func testGrayPalettesLeaveHarmonyShort() throws {
        for mode in [ThemeMode.dark, .light] {
            let canvas = try XCTUnwrap(WallpaperCanvas(size: size, palette: Self.gray(mode), seed: 1))
            XCTAssertEqual(canvas.harmony(3).count, 1, "\(mode)")
        }
    }

    func testEveryStyleDrawsGrayPalettes() throws {
        for mode in [ThemeMode.dark, .light] {
            // Between them, these seeds pick each ASCII subject (Mandelbrot, torus, fire).
            drawEveryStyle(try Self.gray(mode), seeds: [1, 3, 6], "gray \(mode)")
        }
    }

    /// Every built-in theme: about seven minutes in a debug build, so only on request
    /// (`VIBESHED_WALLPAPER_SWEEP=1 swift test --filter WallpaperPaletteSweepTests`), after
    /// adding a theme or a style.
    func testEveryStyleDrawsEveryBuiltInPalette() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VIBESHED_WALLPAPER_SWEEP"] == "1",
            "set VIBESHED_WALLPAPER_SWEEP=1 to draw every style with every built-in theme"
        )
        for theme in BuiltInThemes.all {
            drawEveryStyle(try ThemePalette.resolve(theme.colors, mode: theme.mode), seeds: [1, 2, 3], theme.name)
        }
    }
}
