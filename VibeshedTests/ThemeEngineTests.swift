import AppKit
import CoreGraphics
@testable import Vibeshed
import XCTest

final class JSONCDocumentTests: XCTestCase {
    func testReplacesValuePreservingCommentsAndLayout() throws {
        var document = JSONCDocument(text: """
        {
            // Appearance
            "workbench.colorTheme": "Default Dark Modern", // current theme
            /* fonts */ "editor.fontSize": 14,
        }
        """)
        try document.setValue("Vibeshed", forKey: "workbench.colorTheme")
        XCTAssertEqual(document.text, """
        {
            // Appearance
            "workbench.colorTheme": "Vibeshed", // current theme
            /* fonts */ "editor.fontSize": 14,
        }
        """)
    }

    func testAppendsAfterTrailingComma() throws {
        var document = JSONCDocument(text: "{\n  \"a\": 1,\n}\n")
        try document.setValue("x", forKey: "b")
        XCTAssertEqual(document.text, "{\n  \"a\": 1,\n  \"b\": \"x\"\n}\n")
    }

    func testAppendsAddingComma() throws {
        var document = JSONCDocument(text: "{\n  \"a\": 1 // note\n}\n")
        try document.setValue(true, forKey: "b")
        XCTAssertEqual(document.text, "{\n  \"a\": 1, // note\n  \"b\": true\n}\n")
    }

    func testEmptyInputs() throws {
        var fresh = JSONCDocument(text: nil)
        try fresh.setValue("custom:vibeshed", forKey: "theme")
        XCTAssertEqual(fresh.text, "{\n  \"theme\": \"custom:vibeshed\"\n}\n")

        var compact = JSONCDocument(text: "{}")
        try compact.setValue(1, forKey: "a")
        XCTAssertEqual(compact.text, "{\n  \"a\": 1\n}")
    }

    func testNestedValuesAreReadAndWritten() throws {
        var document = JSONCDocument(text: """
        {
          "theme": {
            "mode": "system", // follow macOS
            "light": "One Light",
            "dark": "One Dark",
          },
          "vim_mode": false
        }
        """)
        var theme = try XCTUnwrap(document.value(forKey: "theme") as? [String: Any])
        XCTAssertEqual(theme["mode"] as? String, "system")
        XCTAssertEqual(document.value(forKey: "vim_mode") as? Bool, false)
        XCTAssertNil(document.value(forKey: "missing"))

        theme["dark"] = "Vibeshed"
        try document.setValue(theme, forKey: "theme")
        let reread = try XCTUnwrap(document.value(forKey: "theme") as? [String: Any])
        XCTAssertEqual(reread["dark"] as? String, "Vibeshed")
        XCTAssertEqual(reread["light"] as? String, "One Light")
        XCTAssertTrue(document.text.contains("\"vim_mode\": false"))
        XCTAssertTrue(document.text.contains("\"dark\": \"Vibeshed\""), "Foundation's `\" : \"` spacing is tightened")
    }

    func testStringsContainingSyntaxAreNotMisparsed() throws {
        var document = JSONCDocument(text: #"{ "url": "http://x/*y*/", "b": "}", "c": 1 }"#)
        XCTAssertEqual(document.value(forKey: "url") as? String, "http://x/*y*/")
        try document.setValue(2, forKey: "c")
        XCTAssertEqual(document.text, #"{ "url": "http://x/*y*/", "b": "}", "c": 2 }"#)
    }

    func testRejectsNonObjects() {
        var document = JSONCDocument(text: "[1, 2]")
        XCTAssertThrowsError(try document.setValue(1, forKey: "a"))
    }
}

final class ThemeFilesTests: XCTestCase {
    func testWritesThroughSymlinksWithoutReplacingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("dotfiles-settings.json")
        let link = root.appendingPathComponent("settings.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let restore = ThemeFiles.snapshot([link.path])
        try ThemeFiles.write("{ \"theme\": 1 }", to: link.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{ \"theme\": 1 }")

        await restore()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{}")
    }
}

final class ThemeCatalogTests: XCTestCase {
    func testConfigThemeReplacesBuiltInAndInherits() throws {
        var config = ThemeConfig()
        config.themes = [
            ThemeDefinition(name: "Nord", base: "Nord", colors: ["accent": "#ff0000"]),
            ThemeDefinition(name: "Midnight", base: "Tokyo Night", colors: ["background": "#000000"],
                            apps: ["vscode": "Tokyo Night"]),
        ]
        let result = ThemeCatalog.build(config: config, generated: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")

        let nord = try XCTUnwrap(result.theme(slug: "nord"))
        XCTAssertEqual(nord.source, .config)
        XCTAssertEqual(nord.palette.accent.hex, "#ff0000")
        XCTAssertEqual(nord.palette.background.hex, "#2e3440", "inherits the built-in Nord")
        XCTAssertEqual(result.themes.filter { $0.slug == "nord" }.count, 1)
        XCTAssertEqual(
            result.themes.firstIndex { $0.slug == "nord" },
            BuiltInThemes.all.firstIndex { $0.name == "Nord" },
            "a replaced theme keeps its position"
        )

        let midnight = try XCTUnwrap(result.theme(slug: "midnight"))
        XCTAssertEqual(midnight.palette.background.hex, "#000000")
        XCTAssertEqual(midnight.palette.accent.hex, "#7aa2f7")
        XCTAssertEqual(midnight.icon, "moon.stars")
        XCTAssertEqual(midnight.appOverrides["vscode"], "Tokyo Night")
    }

    func testBaseErrors() {
        let result = ThemeCatalog.resolve([
            (ThemeDefinition(name: "A", base: "Nowhere"), .config),
            (ThemeDefinition(name: "B", base: "C"), .config),
            (ThemeDefinition(name: "C", base: "B"), .config),
            (ThemeDefinition(name: "D", colors: ["background": "#000000"]), .config),
        ])
        XCTAssertTrue(result.themes.isEmpty)
        XCTAssertEqual(result.errors.count, 4)
        XCTAssertTrue(result.errors[0].contains("not found"))
        XCTAssertTrue(result.errors[1].contains("loops"))
        XCTAssertTrue(result.errors[3].contains("missing colors"))
    }

    func testSlugs() {
        XCTAssertEqual(ResolvedTheme.slug(for: "Rosé Pine"), "rose-pine")
        XCTAssertEqual(ResolvedTheme.slug(for: "  Tokyo   Night!"), "tokyo-night")
        XCTAssertEqual(ResolvedTheme.slug(for: "???"), "")
    }

    func testLoadsOmarchyStyleThemeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let theme = root.appendingPathComponent("osaka-jade")
        let backgrounds = theme.appendingPathComponent("backgrounds")
        try FileManager.default.createDirectory(at: backgrounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        # Osaka Jade
        accent = "#509475"
        background = '#111c18'
        foreground = "#C1C497"   # inline comment
        red = "#FF5345"
        green = "#549e6a"
        yellow = "#459451"
        blue = "#509475"
        magenta = "#D2689C"
        cyan = "#2DD5B7"
        [ignored]
        """.write(to: theme.appendingPathComponent("colors.toml"), atomically: true, encoding: .utf8)
        try Data().write(to: backgrounds.appendingPathComponent("2.png"))
        try Data().write(to: backgrounds.appendingPathComponent("1.jpg"))
        try Data().write(to: theme.appendingPathComponent("light.mode"))

        let definitions = ThemeDirectoryLoader.load(from: root.path)
        XCTAssertEqual(definitions.count, 1)
        let result = ThemeCatalog.resolve(definitions.map { ($0, .directory) })
        let resolved = try XCTUnwrap(result.themes.first)
        XCTAssertEqual(resolved.name, "Osaka Jade")
        XCTAssertEqual(resolved.palette.foreground.hex, "#c1c497")
        XCTAssertEqual(resolved.palette.mode, .light, "light.mode marker")
        XCTAssertEqual(resolved.wallpaper, backgrounds.appendingPathComponent("1.jpg").path)
    }
}

final class ThemeConfigTests: XCTestCase {
    func testEmptyConfigUsesDefaults() throws {
        let config = try JSONDecoder().decode(ThemeConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config, ThemeConfig())
        XCTAssertEqual(config.enabledTargets, ThemeTargetID.defaults)
        XCTAssertFalse(config.enabledTargets.contains(.github))
        XCTAssertTrue(config.livePreview)
    }

    func testPartialConfigDecodes() throws {
        let json = """
        {
          "targets": ["appearance", "iterm", "bogus"],
          "folders": ["~/Projects"],
          "themes": [{ "name": "Mine", "base": "Nord", "mode": "dark", "colors": { "accent": "#ff00ff" } }],
          "templates": [{ "source": "~/t.tpl", "target": "~/out.conf" }]
        }
        """
        let config = try JSONDecoder().decode(ThemeConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.enabledTargets, [.appearance, .iterm])
        XCTAssertEqual(config.themes.first?.colors["accent"], "#ff00ff")
        XCTAssertEqual(config.themes.first?.apps, [:])
        XCTAssertEqual(config.templates.first?.preview, false)
        XCTAssertTrue(config.includeBuiltInThemes)

        let validation = ThemeModule.validate(config)
        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.errors.count, 1)
        XCTAssertTrue(validation.errors[0].contains("bogus"))
    }

    func testValidationCatchesBadThemes() {
        var config = ThemeConfig()
        config.themes = [
            ThemeDefinition(name: "Broken", base: "Nord", colors: ["accent": "red"]),
            ThemeDefinition(name: "Sparse", colors: ["background": "#000", "foreground": "#fff"]),
            ThemeDefinition(name: "Odd", base: "Nord", macosAccent: "teal", apps: ["emacs": "x"]),
        ]
        let errors = ThemeModule.validate(config).errors
        XCTAssertTrue(errors.contains { $0.contains("'accent' is not a hex color") })
        XCTAssertTrue(errors.contains { $0.contains("missing colors") })
        XCTAssertTrue(errors.contains { $0.contains("macosAccent") })
        XCTAssertTrue(errors.contains { $0.contains("unknown app 'emacs'") })
    }
}

final class ThemeBuilderTests: XCTestCase {
    private let palette = (try? ThemePalette.resolve(BuiltInThemes.dracula.colors, mode: .dark))
        ?? ThemePalette(mode: .dark, colors: [:])

    func testVSCodeTheme() throws {
        let theme = VSCodeThemeBuilder.theme(palette, name: "Vibeshed")
        XCTAssertEqual(theme["type"] as? String, "dark")
        let colors = try XCTUnwrap(theme["colors"] as? [String: String])
        XCTAssertEqual(colors["editor.background"], "#282a36")
        XCTAssertEqual(colors["terminal.ansiBrightWhite"], palette.ansi[15].hex)
        XCTAssertEqual(colors["button.foreground"], palette.accent.contrastingText.hex)
        for part in ["Background", "Foreground", "Border"] {
            let noFolder = try XCTUnwrap(colors["statusBar.noFolder\(part)"], "statusBar.noFolder\(part)")
            XCTAssertEqual(noFolder, colors["statusBar.\(part.lowercased())"], "statusBar.noFolder\(part)")
        }
        XCTAssertNoThrow(try JSONFormatting.pretty(theme))
    }

    func testZedTheme() throws {
        let family = ZedThemeBuilder.family(palette, name: "Vibeshed")
        let themes = try XCTUnwrap(family["themes"] as? [[String: Any]])
        let style = try XCTUnwrap(themes.first?["style"] as? [String: Any])
        XCTAssertEqual(style["editor.background"] as? String, "#282a36")
        XCTAssertEqual(style["terminal.ansi.bright_white"] as? String, palette.ansi[15].hex)
        XCTAssertNotNil((style["syntax"] as? [String: Any])?["keyword"])
    }

    func testJetBrainsScheme() throws {
        let icls = JetBrainsSchemeBuilder.scheme(
            palette, id: "_@user_Vibeshed", fontOptions: [#"<option name="EDITOR_FONT_NAME" value="Iosevka" />"#]
        )
        let document = try XMLDocument(xmlString: icls)
        let root = try XCTUnwrap(document.rootElement())
        XCTAssertEqual(root.attribute(forName: "name")?.stringValue, "_@user_Vibeshed")
        XCTAssertEqual(root.attribute(forName: "parent_scheme")?.stringValue, "Darcula")
        XCTAssertEqual(try document.nodes(forXPath: "/scheme/option[@name='EDITOR_FONT_NAME']").count, 1)
        let text = try document.nodes(forXPath: "//option[@name='TEXT']//option[@name='BACKGROUND']/@value")
        XCTAssertEqual(text.first?.stringValue, "282a36")
    }

    func testITermProfileInheritsAndForcesSingleColorSet() throws {
        let profile = ITermTarget.profile(palette, parent: "Default")
        XCTAssertEqual(profile["Guid"] as? String, ITermTarget.profileGUID)
        XCTAssertEqual(profile["Dynamic Profile Parent Name"] as? String, "Default")
        XCTAssertEqual(profile["Use Separate Colors for Light and Dark Mode"] as? Bool, false)
        let background = try XCTUnwrap(profile["Background Color"] as? [String: Any])
        XCTAssertEqual(background["Red Component"] as? Double, palette.background.red)
        XCTAssertNotNil(profile["Ansi 15 Color"])
        XCTAssertNil(ITermTarget.profile(palette, parent: nil)["Dynamic Profile Parent Name"])
    }

    func testBtopThemeAndConfig() {
        let theme = CLIThemeBuilder.btopTheme(palette, themeName: "Dracula")
        XCTAssertTrue(theme.contains("theme[main_bg]=\"\(palette.background.hex)\""))
        XCTAssertTrue(theme.contains("theme[hi_fg]=\"\(palette.accent.hex)\""))
        XCTAssertTrue(theme.contains("theme[gradient_color_7]=\"\(palette.brightForeground.hex)\""))

        let config = "#? Config\ncolor_theme = \"Default\"\ntruecolor = true\n"
        XCTAssertEqual(
            BtopTarget.selectingTheme(in: config),
            "#? Config\ncolor_theme = \"vibeshed\"\ntruecolor = true\n"
        )
        let prepended = BtopTarget.selectingTheme(in: "truecolor = true")
        XCTAssertEqual(prepended, "color_theme = \"vibeshed\"\ntruecolor = true")
        XCTAssertEqual(BtopTarget.selectingTheme(in: nil), "color_theme = \"vibeshed\"\n")
    }

    func testClaudeCodeTheme() throws {
        let theme = ClaudeCodeTarget.theme(palette)
        XCTAssertEqual(theme["base"] as? String, "dark")
        let overrides = try XCTUnwrap(theme["overrides"] as? [String: String])
        XCTAssertEqual(overrides["claude"], palette.accent.hex)
        XCTAssertEqual(overrides["diffAdded"], palette.background.mix(palette.green, 0.15).hex)
    }

    func testBatTmTheme() throws {
        let xml = try CLIThemeBuilder.tmTheme(palette, name: "Vibeshed")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["name"] as? String, "Vibeshed")
        let settings = try XCTUnwrap(plist["settings"] as? [[String: Any]])
        let global = try XCTUnwrap(settings.first?["settings"] as? [String: String])
        XCTAssertEqual(global["background"], "#282a36")
        let comment = try XCTUnwrap(settings.first { ($0["scope"] as? String)?.hasPrefix("comment") == true })
        XCTAssertEqual((comment["settings"] as? [String: String])?["foreground"], palette.muted.hex)
    }

    func testLsdAndMicroThemes() throws {
        let lsd = CLIThemeBuilder.lsdColors(palette, themeName: "Dracula")
        XCTAssertTrue(lsd.contains("  read: \"\(palette.green.hex)\""))
        XCTAssertTrue(lsd.contains("  modified: \"\(palette.orange.hex)\""))
        XCTAssertFalse(lsd.contains("\t"), "YAML must be space-indented")

        let micro = CLIThemeBuilder.microScheme(palette, themeName: "Dracula")
        XCTAssertTrue(micro.contains("color-link default \"\(palette.foreground.hex),\(palette.background.hex)\""))
        XCTAssertTrue(micro.contains("color-link comment \"italic \(palette.muted.hex)\""))
        let lines = micro.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("color-link ") })
    }
}

final class WallpaperStyleTests: XCTestCase {
    private let palette = (try? ThemePalette.resolve(BuiltInThemes.tokyoNight.colors, mode: .dark))
        ?? ThemePalette(mode: .dark, colors: [:])

    private func pixels(_ image: CGImage) -> Data {
        image.dataProvider?.data.map { $0 as Data } ?? Data()
    }

    func testEveryStyleRendersDeterministically() throws {
        let size = CGSize(width: 160, height: 100)
        var renders: [WallpaperStyle: Data] = [:]
        for style in WallpaperStyle.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: style.icon, accessibilityDescription: nil), style.rawValue)
            let choice = WallpaperChoice(style: style, seed: 42, grain: true)
            let first = try XCTUnwrap(WallpaperRenderer.draw(palette, size: size, choice: choice), style.rawValue)
            let second = try XCTUnwrap(WallpaperRenderer.draw(palette, size: size, choice: choice))
            XCTAssertEqual(first.width, 160)
            XCTAssertEqual(pixels(first), pixels(second), "\(style.rawValue) must be reproducible from its seed")
            renders[style] = pixels(first)
        }
        XCTAssertEqual(Set(renders.values).count, WallpaperStyle.allCases.count, "styles must differ")
    }

    func testSeedChangesVariation() throws {
        let size = CGSize(width: 160, height: 100)
        let styles: [WallpaperStyle] = [
            .mesh, .ridges, .bokeh, .lowpoly, .topographic, .pulsar, .guilloche, .sashiko, .attractor, .bauhaus,
            .destijl, .truchet, .terrazzo, .circles, .isometric, .penrose, .maze, .dither, .pipes, .pebbles,
            .pinstripe, .clouds, .azul, .boing, .rain, .flow, .lens, .papercut, .automata, .chladni, .cuttingmat,
        ]
        for style in styles {
            let one = WallpaperRenderer.draw(palette, size: size, choice: .init(style: style, seed: 1, grain: false))
            let two = WallpaperRenderer.draw(palette, size: size, choice: .init(style: style, seed: 2, grain: false))
            let first = try XCTUnwrap(one), second = try XCTUnwrap(two)
            XCTAssertNotEqual(pixels(first), pixels(second), style.rawValue)
        }
    }

    func testRegularSolidsHaveTheRightFaces() {
        let shapes = RegularSolid.all.map { solid in
            [solid.vertices.count, solid.faces.count, Set(solid.faces.map(\.count)).first ?? 0]
        }
        // Tetrahedron, cube, octahedron, dodecahedron, icosahedron: vertices, faces, face size.
        XCTAssertEqual(shapes, [[4, 4, 3], [8, 6, 4], [6, 8, 3], [20, 12, 5], [12, 20, 3]])
        for solid in RegularSolid.all {
            // Every edge is shared by exactly two faces — the faces close the solid.
            var edges: [Set<Int>: Int] = [:]
            for face in solid.faces {
                for (index, vertex) in face.enumerated() {
                    edges[[vertex, face[(index + 1) % face.count]], default: 0] += 1
                }
            }
            XCTAssertTrue(edges.values.allSatisfy { $0 == 2 }, "\(solid.vertices.count)-vertex solid")
        }
    }

    func testHitomezashiRegionsAlternateExactlyAcrossStitches() {
        var rng = SeededGenerator(seed: 3)
        let (columns, rows) = (23, 17)
        let pattern = Hitomezashi(
            rowBits: (0 ... rows).map { _ in rng.int(below: 2) == 1 },
            columnBits: (0 ... columns).map { _ in rng.int(below: 2) == 1 }
        )
        let colors = pattern.regions(columns: columns, rows: rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let color = colors[row * columns + column]
                if column + 1 < columns {
                    XCTAssertEqual(color != colors[row * columns + column + 1], pattern.down(column + 1, row))
                }
                if row + 1 < rows {
                    XCTAssertEqual(color != colors[(row + 1) * columns + column], pattern.across(column, row + 1))
                }
            }
        }
    }

    func testPenroseDeflationTilesTheWheel() {
        func area(_ triangle: RobinsonTriangle) -> Double {
            let (apex, left, right) = (triangle.apex, triangle.left, triangle.right)
            return abs(Double((left.x - apex.x) * (right.y - apex.y) - (right.x - apex.x) * (left.y - apex.y))) / 2
        }
        let wheel = RobinsonTriangle.wheel(center: CGPoint(x: 10, y: -4), radius: 100, rotation: 0.3)
        let tiles = RobinsonTriangle.deflate(wheel, times: 5)
        // Deflation splits triangles without gaps or overlaps…
        XCTAssertEqual(tiles.map(area).reduce(0, +), wheel.map(area).reduce(0, +), accuracy: 1e-6)
        // …into two congruent kinds, thick halves outnumbering thin ones by about φ.
        for kind in [true, false] {
            let areas = tiles.filter { $0.thin == kind }.map(area)
            XCTAssertEqual((areas.max() ?? 0) - (areas.min() ?? 0), 0, accuracy: 1e-9)
        }
        let ratio = Double(tiles.filter { !$0.thin }.count) / Double(tiles.filter(\.thin).count)
        XCTAssertEqual(ratio, RobinsonTriangle.goldenRatio, accuracy: 0.05)
    }

    func testMazeFindsSealedRooms() {
        // ╱╲ over ╲╱ closes a diamond: the four halves inside it are one sealed room.
        let diamond = DiagonalMaze(columns: 2, rows: 2, rising: [true, false, false, true])
        let rooms = diamond.rooms()
        let sealed = rooms.indices.filter { rooms[$0] != nil }
        XCTAssertEqual(sealed, [1, 3, 4, 6])
        XCTAssertEqual(Set(sealed.compactMap { rooms[$0] }).count, 1)
        // Parallel diagonals only make strips that run off the edge.
        let strips = DiagonalMaze(columns: 4, rows: 3, rising: Array(repeating: true, count: 12))
        XCTAssertTrue(strips.rooms().allSatisfy { $0 == nil })
    }

    func testASCIITorusFitsTheFrameWithAHole() {
        let (columns, rows) = (214, 60) // 16:9
        let levels = ASCIITorus(tilt: 1.4, turn: 0.6, spin: 0)
            .render(columns: columns, rows: rows, center: (107, 30), halfHeight: 24)
        let covered = levels.indices.filter { levels[$0] != nil }
        let coveredRows = covered.map { $0 / columns }
        XCTAssertEqual(coveredRows.min() ?? 0, 6, accuracy: 1)
        XCTAssertEqual(coveredRows.max() ?? 0, 54, accuracy: 1)
        XCTAssertTrue(covered.allSatisfy { !(0 ... 1).contains($0 % columns) }, "stays off the edges")
        XCTAssertNil(levels[30 * columns + 107], "the hole")
        let used = Set(levels.compactMap(\.self))
        XCTAssertTrue(used.contains(WallpaperCanvas.asciiRamp.count - 1), "a highlight in @")
        XCTAssertFalse(used.contains(0), "ambient light keeps the shadow side above the lightest dot")
    }

    func testASCIIMandelbrotHasTheSetInsideAndBlankSpaceOutside() {
        let (columns, rows) = (160, 60)
        let values = ASCIIMandelbrot(real: -0.62, span: 3.2).render(columns: columns, rows: rows)
        // The cell holding c = −0.2 is in the main cardioid; the corners escape at once.
        let column = Int((-0.2 + 0.62) / (3.2 / Double(rows) / 2) + Double(columns) / 2)
        XCTAssertNil(values[rows / 2 * columns + column])
        XCTAssertLessThan(try XCTUnwrap(values[0]), 0.3)
        XCTAssertEqual(values[0], values[rows * columns - 1 - (columns - 1)], "symmetric about the real axis")
    }

    func testASCIIFireBurnsFromTheBottomAndCoolsAsItRises() {
        var rng = SeededGenerator(seed: 1)
        let (columns, rows) = (80, 40)
        let heat = ASCIIFire(fuel: Array(repeating: 0.8, count: columns), cooling: 1.9 / Double(rows))
            .render(rows: rows, rng: &rng)
        func mean(_ row: Int) -> Double {
            heat[row * columns ..< (row + 1) * columns].reduce(0, +) / Double(columns)
        }
        XCTAssertGreaterThan(mean(rows - 1), 0.4)
        XCTAssertGreaterThan(mean(rows - 1), mean(rows / 2))
        XCTAssertEqual(mean(0), 0, "the top is cold")
    }

    func testStyleResolution() {
        XCTAssertEqual(WallpaperStyle.resolve("Ridges", slug: "x"), .ridges)
        XCTAssertNil(WallpaperStyle.resolve("plasma", slug: "x"))
        let auto = WallpaperStyle.resolve("auto", slug: "tokyo-night")
        XCTAssertNotNil(auto)
        XCTAssertEqual(auto, WallpaperStyle.resolve("auto", slug: "tokyo-night"), "auto is stable per theme")
        XCTAssertNotEqual(auto, .solid)

        var config = ThemeConfig()
        config.wallpaperStyle = "plasma"
        XCTAssertTrue(ThemeModule.validate(config).errors.contains { $0.contains("wallpaperStyle 'plasma'") })
        config.wallpaperStyle = "auto"
        XCTAssertTrue(ThemeModule.validate(config).isValid)
    }
}
