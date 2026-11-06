import CoreGraphics
@testable import Vibeshed
import XCTest
import Yams

final class MacStyleTests: XCTestCase {
    // MARK: - Parsing

    func testGlassValues() {
        XCTAssertEqual(MacStyle.glass("clear"), 0)
        XCTAssertEqual(MacStyle.glass(" Tinted "), 1)
        XCTAssertEqual(MacStyle.glass("0.4"), 0.4)
        XCTAssertNil(MacStyle.glass("1.5"))
        XCTAssertNil(MacStyle.glass("-0.1"))
        XCTAssertNil(MacStyle.glass("frosted"))
    }

    func testIconStyleNames() throws {
        for name in IconStyle.configNames {
            let style = try XCTUnwrap(IconStyle(name), name)
            XCTAssertEqual(style.configName, name)
            XCTAssertEqual(IconStyle(systemName: style.systemName), style)
        }
        XCTAssertEqual(IconStyle("default"), .systemDefault)
        XCTAssertEqual(IconStyle("default")?.systemName, "RegularLight")
        XCTAssertEqual(IconStyle("auto")?.systemName, "RegularAutomatic")
        XCTAssertEqual(IconStyle("dark")?.systemName, "RegularDark")
        XCTAssertEqual(IconStyle("Clear Dark")?.systemName, "ClearDark")
        XCTAssertEqual(IconStyle("tinted-auto")?.systemName, "TintedAutomatic")
        XCTAssertEqual(IconStyle("regular-light")?.systemName, "RegularLight")
        for bad in ["", "sparkly", "clear-da", "tinted-dark-extra", "dark-clear"] {
            XCTAssertNil(IconStyle(bad), bad)
        }
    }

    /// SkyLight's numbering, as measured on macOS 27.2 by saving raw values and reading
    /// back the `AppleIconAppearanceTheme` name it wrote.
    @MainActor
    func testIconThemeNumbering() {
        let measured: [Int: String] = [
            0: "RegularAutomatic", 2: "RegularDark", 4: "ClearLight", 7: "TintedLight", 8: "TintedDark",
        ]
        for (value, name) in measured {
            XCTAssertEqual(IconAppearance.themeNames[value], name)
        }
        XCTAssertEqual(IconAppearance.themeNames[1], IconStyle.systemDefault.systemName)
        XCTAssertEqual(Set(IconAppearance.themeNames).count, 9)
        for name in IconAppearance.themeNames {
            XCTAssertNotNil(IconStyle(systemName: name), name)
        }
    }

    func testMenuBarBackgroundDecodesBooleansAndWords() throws {
        let yaml = """
        - { name: a, macosMenuBarBackground: true }
        - { name: b, macosMenuBarBackground: false }
        - { name: c, macosMenuBarBackground: hide }
        - { name: d }
        """
        let themes = try YAMLDecoder().decode([ThemeDefinition].self, from: yaml)
        XCTAssertEqual(themes.map(\.macosMenuBarBackground), [.show, .hide, .hide, nil])
        XCTAssertThrowsError(
            try YAMLDecoder().decode([ThemeDefinition].self, from: "[{ name: e, macosMenuBarBackground: maybe }]")
        )
    }

    func testConfigThemeSettings() throws {
        let yaml = "[{ name: a, base: Nord, macosGlass: 0.25, macosIconStyle: clear-dark }]"
        var config = ThemeConfig()
        config.themes = try YAMLDecoder().decode([ThemeDefinition].self, from: yaml)
        let theme = try XCTUnwrap(ThemeCatalog.build(config: config, generated: nil).theme(slug: "a"))
        XCTAssertEqual(theme.macStyle, MacStyle(glass: 0.25, iconStyle: IconStyle(.clear, .dark)))
    }

    func testInvalidSettingsFailValidation() {
        var config = ThemeConfig()
        config.themes = [
            ThemeDefinition(name: "Frosted", base: "Nord", macosGlass: "frosted"),
            ThemeDefinition(name: "Sparkly", base: "Nord", macosIconStyle: "sparkly"),
        ]
        let errors = ThemeModule.validate(config).errors
        XCTAssertTrue(errors.contains { $0.contains("Theme 'Frosted'") && $0.contains("macosGlass") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("Theme 'Sparkly'") && $0.contains("macosIconStyle") }, "\(errors)")
    }

    // MARK: - Built-in themes

    func testBuiltInOpinions() throws {
        let catalog = ThemeCatalog.build(config: ThemeConfig(), generated: nil)
        XCTAssertTrue(catalog.errors.isEmpty, "\(catalog.errors)")
        // Every name in the table is a real theme (a rename would silently drop its style).
        for name in BuiltInThemes.macStyles.keys {
            XCTAssertNotNil(catalog.theme(slug: ResolvedTheme.slug(for: name)), name)
        }
        let macOS9 = try XCTUnwrap(catalog.theme(slug: "mac-os-9"))
        XCTAssertEqual(macOS9.macStyle, MacStyle(glass: 1, menuBarBackground: .show))
        XCTAssertEqual(catalog.theme(slug: "hackerman")?.macStyle.iconStyle, IconStyle(.tinted))
        XCTAssertEqual(catalog.theme(slug: "vantablack")?.macStyle.iconStyle, IconStyle(.clear))
        // Most themes leave your own settings alone.
        XCTAssertEqual(catalog.theme(slug: "tokyo-night")?.macStyle, MacStyle())
        XCTAssertEqual(catalog.themes.filter { !$0.macStyle.isEmpty }.count, BuiltInThemes.macStyles.count)
    }

    func testBaseInheritsAndOverridesTheStyle() throws {
        var config = ThemeConfig()
        config.themes = [
            ThemeDefinition(name: "Mine", base: "Mac OS 9"),
            ThemeDefinition(name: "Mine Clear", base: "Mac OS 9", macosGlass: "clear", macosMenuBarBackground: .hide),
        ]
        let catalog = ThemeCatalog.build(config: config, generated: nil)
        XCTAssertEqual(catalog.theme(slug: "mine")?.macStyle, MacStyle(glass: 1, menuBarBackground: .show))
        XCTAssertEqual(catalog.theme(slug: "mine-clear")?.macStyle, MacStyle(glass: 0, menuBarBackground: .hide))
    }

    func testStoredStyleRoundTrips() {
        let style = MacStyle(glass: 0.35, iconStyle: IconStyle(.tinted, .light), menuBarBackground: .hide)
        XCTAssertEqual(MacStyle(stored: style.stored), style)
        XCTAssertEqual(MacStyle(stored: [:]), MacStyle())
        let definition = ThemeDefinition(name: "x").with(style)
        XCTAssertEqual(try MacStyle(definition), style)
        XCTAssertEqual(style.summary, "Tinted light icons · Glass 35% tinted · No menu bar background")
        XCTAssertNil(MacStyle().summary)
    }

    // MARK: - Liquid Glass values

    @MainActor
    func testGlassSettingEncoding() throws {
        let tint = LiquidGlass.Setting(tint: 0.45523807)
        XCTAssertEqual(tint.stored, "tint:0.45523807")
        XCTAssertEqual(LiquidGlass.Setting(stored: tint.stored), tint)
        XCTAssertEqual(tint.bytes, [0xF7, 0x14, 0xE9, 0x3E, 0], "the bytes macOS 27.2 returned for this tint")
        let other = try XCTUnwrap(LiquidGlass.Setting(stored: "raw:0100000001"))
        XCTAssertNil(other.tint)
        XCTAssertEqual(other.stored, "raw:0100000001")
        XCTAssertNil(LiquidGlass.Setting(stored: "raw:01"))
        XCTAssertNil(LiquidGlass.Setting(stored: "glass"))
    }
}

// MARK: - Giving your own settings back

@MainActor
final class ThemedSystemSettingTests: XCTestCase {
    private var value: String? = "yours"
    private var writes: [String] = []
    private var suite = ""

    override func setUp() async throws {
        suite = "vibeshed.tests.\(UUID().uuidString)"
        value = "yours"
        writes = []
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private var setting: ThemedSystemSetting {
        ThemedSystemSetting(
            name: "test",
            read: { [unowned self] in value },
            write: { [unowned self] new in
                writes.append(new)
                value = new
                return true
            },
            unavailable: "needs a newer macOS",
            suiteName: suite
        )
    }

    func testAThemeWithoutAnOpinionChangesNothing() {
        XCTAssertEqual(setting.apply(nil), .skipped("the theme leaves it as is"))
        XCTAssertEqual(writes, [])
    }

    func testYourSettingComesBackAfterThemesWithOpinions() {
        XCTAssertEqual(setting.apply("tinted"), .applied())
        XCTAssertEqual(setting.apply("clear"), .applied())
        XCTAssertEqual(setting.apply(nil), .applied())
        XCTAssertEqual(writes, ["tinted", "clear", "yours"])
        // Forgotten once it's back.
        XCTAssertEqual(setting.apply(nil), .skipped("the theme leaves it as is"))
    }

    func testASettingYouChangeYourselfStays() {
        _ = setting.apply("tinted")
        value = "picked by hand"
        XCTAssertEqual(setting.apply(nil), .applied())
        XCTAssertEqual(value, "picked by hand")
        XCTAssertEqual(writes, ["tinted"])
    }

    func testAHandPickedSettingIsTheOneGivenBackLater() {
        _ = setting.apply("tinted")
        value = "picked by hand"
        _ = setting.apply("clear")
        _ = setting.apply(nil)
        XCTAssertEqual(value, "picked by hand")
    }

    func testAlreadyMatchingIsNotRewritten() {
        value = "tinted"
        XCTAssertEqual(setting.apply("tinted"), .applied())
        XCTAssertEqual(setting.apply(nil), .applied())
        XCTAssertEqual(writes, [])
    }

    func testPreviewRevertRestoresTheValueAndWhatIsRemembered() async {
        _ = setting.apply("tinted") // committed theme
        let restore = setting.snapshot()
        _ = setting.apply(nil) // previewing a theme without an opinion gives yours back…
        XCTAssertEqual(value, "yours")
        await restore?() // …Escape puts the committed theme's setting back
        XCTAssertEqual(value, "tinted")
        // …and still knows yours.
        _ = setting.apply(nil)
        XCTAssertEqual(value, "yours")
    }

    func testUnavailableSetting() {
        value = nil
        XCTAssertEqual(setting.apply("tinted"), .skipped("needs a newer macOS"))
        XCTAssertNil(setting.snapshot())
        XCTAssertEqual(writes, [])
    }

    func testFailedWrite() {
        let failing = ThemedSystemSetting(
            name: "test", read: { "yours" }, write: { _ in false }, unavailable: "", suiteName: suite
        )
        XCTAssertEqual(failing.apply("tinted"), .failed("macOS didn't take the change"))
    }
}

// MARK: - From the wallpaper

final class GeneratedMacStyleTests: XCTestCase {
    private let size = 96

    private func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    /// A smooth vertical gradient between two colors.
    private func gradient(_ top: CGColor, _ bottom: CGColor) throws -> CGImage {
        try image { context in
            let gradient = CGGradient(colorsSpace: nil, colors: [bottom, top] as CFArray, locations: nil)!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
        }
    }

    /// Two-pixel stripes of `colors`, in rows from `fromRow` (0 = top) down.
    private func stripes(_ colors: [CGColor], fromRow: Int = 0, over base: CGColor) throws -> CGImage {
        try image { context in
            context.setFillColor(base)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            for column in stride(from: 0, to: size, by: 2) {
                context.setFillColor(colors[(column / 2) % colors.count])
                context.fill(CGRect(x: column, y: 0, width: 2, height: size - fromRow))
            }
        }
    }

    private let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    func testCalmGradientKeepsClearGlassAndNoBackground() throws {
        let calm = try gradient(CGColor(srgbRed: 0.9, green: 0.7, blue: 0.5, alpha: 1),
                                CGColor(srgbRed: 0.5, green: 0.3, blue: 0.6, alpha: 1))
        let style = try XCTUnwrap(ThemeGenerator.macStyle(from: calm))
        XCTAssertEqual(style.glass, 0)
        XCTAssertEqual(style.menuBarBackground, .hide)
        XCTAssertNil(style.iconStyle, "orange to purple isn't one hue")
    }

    func testBusyPictureGetsTintedGlassAndABackground() throws {
        let busy = try stripes([.black, .white], over: gray)
        let style = try XCTUnwrap(ThemeGenerator.macStyle(from: busy))
        XCTAssertEqual(style.glass, 0.75)
        XCTAssertEqual(style.menuBarBackground, .show)
    }

    func testOnlyTheStripUnderTheMenuBarDecidesTheBackground() throws {
        // Busy below, calm top: the menu bar reads fine.
        let calmTop = try stripes([.black, .white], fromRow: 8, over: gray)
        XCTAssertEqual(ThemeGenerator.macStyle(from: calmTop)?.menuBarBackground, .hide)
        // A light half and a dark half under the menu bar: some of its text would vanish.
        let split = try image { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
            context.setFillColor(.black)
            context.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        }
        let style = try XCTUnwrap(ThemeGenerator.macStyle(from: split))
        XCTAssertEqual(style.menuBarBackground, .show)
        XCTAssertLessThan(try XCTUnwrap(style.glass), 0.1, "one edge isn't a busy picture")
    }

    func testOneVividHueTintsTheIcons() throws {
        let orange = try gradient(CGColor(srgbRed: 1, green: 0.6, blue: 0.2, alpha: 1),
                                  CGColor(srgbRed: 0.7, green: 0.3, blue: 0.05, alpha: 1))
        XCTAssertEqual(ThemeGenerator.macStyle(from: orange)?.iconStyle, IconStyle(.tinted))
        // Pale or grey pictures have no hue to speak of.
        let pale = try gradient(CGColor(srgbRed: 0.95, green: 0.93, blue: 0.9, alpha: 1),
                                CGColor(srgbRed: 0.6, green: 0.6, blue: 0.62, alpha: 1))
        XCTAssertNil(ThemeGenerator.macStyle(from: pale)?.iconStyle)
    }
}
