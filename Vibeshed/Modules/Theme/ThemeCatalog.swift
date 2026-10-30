import Foundation

/// A theme ready to apply: palette resolved, inheritance flattened, paths expanded.
struct ResolvedTheme: Sendable, Equatable, Identifiable {
    enum Source: String, Sendable {
        case builtIn = "Built-in"
        case directory = "Themes folder"
        case config = "Config"
        case generated = "Generated"
    }

    let name: String
    let slug: String
    let palette: ThemePalette
    /// Expanded path to an image file, if the theme has one.
    let wallpaper: String?
    /// Style for a generated wallpaper, when the theme sets one.
    let wallpaperStyle: String?
    let icon: String
    let subtitle: String?
    let keywords: [String]
    let macosAccent: String?
    let appOverrides: [String: String]
    let source: Source
    /// Slugs of the opposite-mode themes this one switches to when the system does; empty
    /// for a theme that is specifically light or dark.
    var counterparts: [String] = []

    var id: String { slug }

    var activeInfo: ActiveThemeInfo {
        ActiveThemeInfo(name: name, slug: slug, palette: palette)
    }

    static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let parts = folded.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.joined(separator: "-")
    }
}

/// Builds the list of available themes from built-ins, the themes directory, config,
/// and the last wallpaper-generated palette. Later sources replace earlier ones with
/// the same name, so config can redefine a built-in.
enum ThemeCatalog {
    struct Result: Sendable {
        let themes: [ResolvedTheme]
        let errors: [String]

        func theme(slug: String) -> ResolvedTheme? {
            themes.first { $0.slug == slug }
        }

        /// What `current` should give way to with the system in `mode`: nil if it already
        /// matches or has no other half. `preferred` picks among a family's variants.
        func counterpart(
            of current: ResolvedTheme,
            for mode: ThemeMode,
            preferring preferred: String? = nil
        ) -> ResolvedTheme? {
            guard current.palette.mode != mode else { return nil }
            let slug = current.counterparts.first { $0 == preferred } ?? current.counterparts.first
            return slug.flatMap(theme(slug:))
        }
    }

    static func build(config: ThemeConfig, generated: ThemeDefinition?) -> Result {
        var definitions: [(ThemeDefinition, ResolvedTheme.Source)] = []
        if config.includeBuiltInThemes {
            definitions += BuiltInThemes.all.map { ($0, .builtIn) }
        }
        definitions += ThemeDirectoryLoader.load(from: config.themesDirectory).map { ($0, .directory) }
        definitions += config.themes.map { ($0, .config) }
        if let generated {
            definitions.append((generated, .generated))
        }
        return resolve(definitions)
    }

    static func resolve(_ definitions: [(ThemeDefinition, ResolvedTheme.Source)]) -> Result {
        // Last definition per slug wins, but keeps the first one's position in the list.
        var order: [String] = []
        var bySlug: [String: (ThemeDefinition, ResolvedTheme.Source)] = [:]
        for entry in definitions {
            let slug = ResolvedTheme.slug(for: entry.0.name)
            guard !slug.isEmpty else { continue }
            if bySlug[slug] == nil { order.append(slug) }
            bySlug[slug] = entry
        }

        var themes: [ResolvedTheme] = []
        var errors: [String] = []
        for slug in order {
            guard let (definition, source) = bySlug[slug] else { continue }
            do {
                let flat = try flatten(definition, lookup: bySlug, visiting: [])
                themes.append(try makeTheme(flat, slug: slug, source: source))
            } catch {
                errors.append("Theme '\(definition.name)': \(error.localizedDescription)")
            }
        }
        let declared = order.compactMap { bySlug[$0]?.0 }.compactMap { definition in
            definition.pair.map { (name: definition.name, pair: $0) }
        }
        linkPairs(&themes, declared: declared, errors: &errors)
        return Result(themes: themes, errors: errors)
    }

    /// Fills in `counterparts`, both ways, from `pair:` settings and then the built-in
    /// table. A table entry that no longer holds (a built-in redefined in the same mode,
    /// or left out) just doesn't apply.
    private static func linkPairs(
        _ themes: inout [ResolvedTheme],
        declared: [(name: String, pair: String)],
        errors: inout [String]
    ) {
        let positions = Dictionary(uniqueKeysWithValues: themes.enumerated().map { ($1.slug, $0) })
        func position(of name: String) -> Int? {
            positions[ResolvedTheme.slug(for: name)]
        }
        func link(_ first: Int, _ second: Int) {
            if !themes[first].counterparts.contains(themes[second].slug) {
                themes[first].counterparts.append(themes[second].slug)
            }
            if !themes[second].counterparts.contains(themes[first].slug) {
                themes[second].counterparts.append(themes[first].slug)
            }
        }

        for (name, pair) in declared {
            guard let first = position(of: name) else { continue }
            guard let second = position(of: pair) else {
                errors.append("Theme '\(name)': pair '\(pair)' not found")
                continue
            }
            guard themes[first].palette.mode != themes[second].palette.mode else {
                let mode = themes[first].palette.mode.rawValue
                errors.append("Theme '\(name)': pair '\(pair)' is \(mode) too, a pair needs one of each")
                continue
            }
            link(first, second)
        }
        for family in BuiltInThemes.pairs {
            guard let light = position(of: family.light), themes[light].palette.mode == .light else { continue }
            for dark in family.darks.compactMap(position(of:)) where themes[dark].palette.mode == .dark {
                link(light, dark)
            }
        }
    }

    /// Merges a definition over its `base` chain (base values first, own values win).
    private static func flatten(
        _ definition: ThemeDefinition,
        lookup: [String: (ThemeDefinition, ResolvedTheme.Source)],
        visiting: Set<String>
    ) throws -> ThemeDefinition {
        guard let baseName = definition.base else { return definition }
        let baseSlug = ResolvedTheme.slug(for: baseName)
        guard !visiting.contains(baseSlug) else { throw ThemeCatalogError.baseCycle(baseName) }
        // A theme may extend the definition it replaces (`name: Nord`, `base: Nord`):
        // resolve the base against the built-ins when the lookup points back at itself.
        let candidate: ThemeDefinition? = if ResolvedTheme.slug(for: definition.name) == baseSlug {
            BuiltInThemes.all.first { ResolvedTheme.slug(for: $0.name) == baseSlug }
        } else {
            lookup[baseSlug]?.0
        }
        guard let baseDefinition = candidate else { throw ThemeCatalogError.unknownBase(baseName) }
        let base = try flatten(
            baseDefinition, lookup: lookup, visiting: visiting.union([ResolvedTheme.slug(for: definition.name)])
        )

        var merged = definition
        merged.base = nil
        merged.mode = definition.mode ?? base.mode
        merged.colors = base.colors.merging(definition.colors) { _, own in own }
        merged.wallpaper = definition.wallpaper ?? base.wallpaper
        merged.wallpaperStyle = definition.wallpaperStyle ?? base.wallpaperStyle
        merged.icon = definition.icon ?? base.icon
        merged.macosAccent = definition.macosAccent ?? base.macosAccent
        merged.apps = base.apps.merging(definition.apps) { _, own in own }
        return merged
    }

    private static func makeTheme(
        _ definition: ThemeDefinition,
        slug: String,
        source: ResolvedTheme.Source
    ) throws -> ResolvedTheme {
        let palette = try ThemePalette.resolve(definition.colors, mode: definition.mode)
        return ResolvedTheme(
            name: definition.name,
            slug: slug,
            palette: palette,
            wallpaper: definition.wallpaper.flatMap(resolveWallpaper),
            wallpaperStyle: definition.wallpaperStyle,
            icon: definition.icon ?? (palette.mode == .dark ? "moon.fill" : "sun.max.fill"),
            subtitle: definition.subtitle,
            keywords: definition.keywords,
            macosAccent: definition.macosAccent,
            appOverrides: definition.apps,
            source: source
        )
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp", "gif"]

    /// An image file as-is, or the first image (sorted) inside a folder.
    static func resolveWallpaper(_ path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return expanded }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? []
        return files.sorted()
            .first { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { (expanded as NSString).appendingPathComponent($0) }
    }
}

enum ThemeCatalogError: LocalizedError {
    case unknownBase(String)
    case baseCycle(String)

    var errorDescription: String? {
        switch self {
        case let .unknownBase(name): "base theme '\(name)' not found"
        case let .baseCycle(name): "base chain loops back to '\(name)'"
        }
    }
}

// MARK: - Themes directory

/// Loads Omarchy-style theme folders: `<themes>/<name>/colors.toml` (flat
/// `key = "value"` lines), plus optional `backgrounds/` and `light.mode`.
enum ThemeDirectoryLoader {
    static func load(from directory: String) -> [ThemeDefinition] {
        let root = NSString(string: directory).expandingTildeInPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted().compactMap { entry in
            let folder = (root as NSString).appendingPathComponent(entry)
            let colorsPath = (folder as NSString).appendingPathComponent("colors.toml")
            guard let text = try? String(contentsOfFile: colorsPath, encoding: .utf8) else { return nil }
            var colors = parseColorsTOML(text)
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("light.mode")) {
                colors["mode"] = colors["mode"] ?? "light"
            }
            let backgrounds = (folder as NSString).appendingPathComponent("backgrounds")
            return ThemeDefinition(
                name: displayName(forFolder: entry),
                colors: colors,
                wallpaper: FileManager.default.fileExists(atPath: backgrounds) ? backgrounds : nil,
                icon: "folder"
            )
        }
    }

    /// `key = "value"` / `key = value` lines; comments, blank lines and `[sections]` ignored.
    static func parseColorsTOML(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("["),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let rest = value.dropFirst()
                value = String(rest.prefix { $0 != quote })
            } else if let comment = value.firstIndex(of: "#"), comment != value.startIndex {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// `tokyo-night` → `Tokyo Night`.
    static func displayName(forFolder folder: String) -> String {
        folder.split { $0 == "-" || $0 == "_" }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
