@testable import Vibeshed
import XCTest

/// Which themes are light/dark halves of one design, and what applying each kind does to
/// the system's Auto appearance.
final class ThemePairingTests: XCTestCase {
    private static let fullPalette = [
        "background": "#000000", "foreground": "#ffffff", "red": "#ff0000", "green": "#00ff00",
        "yellow": "#ffff00", "blue": "#0000ff", "magenta": "#ff00ff", "cyan": "#00ffff",
    ]

    func testBuiltInPairsAllResolveToOppositeModes() throws {
        let result = ThemeCatalog.build(config: ThemeConfig(), generated: nil)
        for family in BuiltInThemes.pairs {
            let light = try XCTUnwrap(result.theme(slug: ResolvedTheme.slug(for: family.light)), family.light)
            XCTAssertEqual(light.palette.mode, .light, family.light)
            XCTAssertEqual(light.counterparts, family.darks.map(ResolvedTheme.slug(for:)))
            for name in family.darks {
                let dark = try XCTUnwrap(result.theme(slug: ResolvedTheme.slug(for: name)), name)
                XCTAssertEqual(dark.palette.mode, .dark, name)
                XCTAssertEqual(dark.counterparts, [light.slug])
            }
        }
        XCTAssertEqual(try XCTUnwrap(result.theme(slug: "dracula")).counterparts, [], "no light half")
    }

    func testCounterpartOnlyWhenModeDiffers() throws {
        let result = ThemeCatalog.build(config: ThemeConfig(), generated: nil)
        let latte = try XCTUnwrap(result.theme(slug: "catppuccin-latte"))
        let macchiato = try XCTUnwrap(result.theme(slug: "catppuccin-macchiato"))
        let dracula = try XCTUnwrap(result.theme(slug: "dracula"))

        XCTAssertNil(result.counterpart(of: latte, for: .light), "already matches")
        XCTAssertEqual(result.counterpart(of: latte, for: .dark)?.slug, "catppuccin-mocha", "first listed")
        XCTAssertEqual(
            result.counterpart(of: latte, for: .dark, preferring: "catppuccin-macchiato")?.slug,
            "catppuccin-macchiato",
            "back to the variant the last switch left"
        )
        XCTAssertEqual(
            result.counterpart(of: latte, for: .dark, preferring: "dracula")?.slug,
            "catppuccin-mocha",
            "a remembered theme from another family doesn't count"
        )
        XCTAssertEqual(result.counterpart(of: macchiato, for: .light)?.slug, "catppuccin-latte")
        XCTAssertNil(result.counterpart(of: dracula, for: .light), "stays put, the system mode was its own call")
    }

    func testConfigPairLinksBothWays() {
        var config = ThemeConfig()
        config.themes = [
            ThemeDefinition(name: "Midnight", base: "Tokyo Night", pair: "Daybreak"),
            ThemeDefinition(name: "Daybreak", base: "Tokyo Night Day"),
            ThemeDefinition(name: "Nord", base: "Nord", colors: ["accent": "#ff0000"]),
        ]
        let result = ThemeCatalog.build(config: config, generated: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.theme(slug: "midnight")?.counterparts, ["daybreak"])
        XCTAssertEqual(result.theme(slug: "daybreak")?.counterparts, ["midnight"], "doesn't inherit its base's pair")
        XCTAssertEqual(result.theme(slug: "nord")?.counterparts, ["nord-light"], "a tweaked built-in stays paired")
    }

    func testPairErrors() {
        var config = ThemeConfig()
        config.themes = [
            ThemeDefinition(name: "Lost", base: "Nord", pair: "Nowhere"),
            ThemeDefinition(name: "Same", base: "Nord", pair: "Dracula"),
        ]
        let errors = ThemeModule.validate(config).errors
        XCTAssertTrue(errors.contains { $0.hasPrefix("Theme 'Lost'") && $0.contains("not found") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.hasPrefix("Theme 'Same'") && $0.contains("dark too") }, "\(errors)")
    }

    func testRedefinedBuiltInInTheSameModeDropsItsPair() {
        let result = ThemeCatalog.resolve([
            (ThemeDefinition(name: "Nord", mode: .light, colors: Self.fullPalette), .config),
            (ThemeDefinition(name: "Nord Light", mode: .light, colors: Self.fullPalette), .config),
        ])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.themes.map(\.counterparts), [[], []])
    }

    func testAutoAppearanceChanges() {
        func change(paired: Bool, auto: Bool, turnedOff: Bool) -> AppearanceTarget.AutoChange {
            AppearanceTarget.autoChange(themeIsPaired: paired, autoIsOn: auto, turnedAutoOff: turnedOff)
        }
        XCTAssertEqual(change(paired: false, auto: true, turnedOff: false), .turnOff)
        XCTAssertEqual(change(paired: false, auto: false, turnedOff: false), .none, "already off")
        XCTAssertEqual(change(paired: true, auto: false, turnedOff: true), .restore)
        XCTAssertEqual(change(paired: true, auto: false, turnedOff: false), .none, "the user's own choice stays")
        XCTAssertEqual(change(paired: true, auto: true, turnedOff: true), .none, "already back on")
        XCTAssertEqual(change(paired: true, auto: true, turnedOff: false), .none)
    }
}
