import Foundation
import SwiftUI

/// What a preview panel should show as the theme's desktop.
enum ThemeWallpaperPreview: Sendable, Equatable {
    case image(String)
    case generated(WallpaperChoice)
}

/// Generated-wallpaper styles: `theme/wallpaperStyle` browses them with live preview on
/// the current theme, `theme/shuffleWallpaper` re-rolls the current style's variation.
extension ThemeModule {
    static let wallpaperStyleActionID = ActionID(module: "theme", name: "wallpaperStyle")
    private static let styleDefaultsKey = "theme.wallpaper.style"
    private static let seedDefaultsKey = "theme.wallpaper.seed"

    /// The style for `theme`: its own `wallpaperStyle` from config, else the one picked
    /// with `theme/wallpaperStyle`, else config's default.
    func wallpaperChoice(for theme: ResolvedTheme, style override: WallpaperStyle? = nil) -> WallpaperChoice {
        let picked = UserDefaults.standard.string(forKey: Self.styleDefaultsKey)
        let style = override
            ?? theme.wallpaperStyle.flatMap { WallpaperStyle.resolve($0, slug: theme.slug) }
            ?? picked.flatMap { WallpaperStyle.resolve($0, slug: theme.slug) }
            ?? WallpaperStyle.resolve(config.wallpaperStyle, slug: theme.slug)
            ?? .glow
        let variation = UInt64(max(UserDefaults.standard.integer(forKey: Self.seedDefaultsKey), 0))
        return WallpaperChoice(style: style, seed: StableHash.of(theme.slug) &+ variation, grain: config.wallpaperGrain)
    }

    /// What applying `theme` would put on the desktop; nil when the wallpaper isn't touched.
    func previewWallpaper(for theme: ResolvedTheme) -> ThemeWallpaperPreview? {
        guard config.enabledTargets.contains(.wallpaper) else { return nil }
        if let image = theme.wallpaper { return .image(image) }
        return config.generateWallpapers ? .generated(wallpaperChoice(for: theme)) : nil
    }

    func wallpaperStyleOptions() async -> [ParameterOption] {
        guard let theme = await currentTheme() else { return [] }
        let current = wallpaperChoice(for: theme).style
        return WallpaperStyle.allCases.map { style in
            let choice = wallpaperChoice(for: theme, style: style)
            return ParameterOption(
                id: style.rawValue,
                label: style.displayName,
                subtitle: style.summary,
                iconName: style.icon,
                isCurrent: style == current,
                makePreview: { AnyView(WallpaperStylePreview(theme: theme, style: style, choice: choice)) }
            )
        }
    }

    func previewWallpaperStyle(_ optionID: String) async {
        guard let theme = await currentTheme(), let style = WallpaperStyle(rawValue: optionID) else { return }
        let options = ThemeApplier.Options(wallpaper: wallpaperChoice(for: theme, style: style), only: [.wallpaper])
        let isCurrent = theme.wallpaper == nil && style == wallpaperChoice(for: theme).style
        await applier.preview(theme.generatingWallpaper(), config: config, options: options, isCurrent: isCurrent)
    }

    /// Applies a generated wallpaper for the current theme — with a newly picked style,
    /// or (`reshuffle`) the same style in a new variation.
    func applyWallpaper(style: WallpaperStyle?, reshuffle: Bool) async -> ActionResult {
        guard let theme = await currentTheme() else {
            return .showResult(title: "Wallpaper", body: "Apply a theme first")
        }
        let defaults = UserDefaults.standard
        if let style { defaults.set(style.rawValue, forKey: Self.styleDefaultsKey) }
        if reshuffle { defaults.set(defaults.integer(forKey: Self.seedDefaultsKey) &+ 1, forKey: Self.seedDefaultsKey) }
        // An explicit pick wins even over a style the theme sets for itself in config.
        let options = ThemeApplier.Options(wallpaper: wallpaperChoice(for: theme, style: style), only: [.wallpaper])
        let results = await applier.apply(theme.generatingWallpaper(), config: config, options: options)
        await eventBus?.publish(.moduleActionsChanged(moduleID: id))
        return Self.summary(theme, results)
    }

    /// The applied theme, if it's still in the catalog.
    func currentTheme() async -> ResolvedTheme? {
        let slug = await MainActor.run { ActiveTheme.shared.committed?.slug }
        return slug.flatMap { catalog.theme(slug: $0) }
    }

    // MARK: - Actions

    func wallpaperStyleAction() -> ThemeAction {
        ThemeAction(
            id: Self.wallpaperStyleActionID,
            title: "Choose Wallpaper Style…",
            subtitle: "Generate the wallpaper from the theme — each style previews live as you move",
            iconName: "photo.on.rectangle.angled",
            relevanceScore: 0.75,
            keywords: ["wallpaper", "background", "desktop", "style", "generate", "theme"]
                + WallpaperStyle.allCases.map(\.rawValue),
            parameters: [
                ActionParameter(
                    id: "style", label: "Style", type: .dynamicSelection(hint: "style"),
                    isRequired: true, livePreview: true
                ),
            ]
        ) { values in
            guard let style = values["style"].flatMap(WallpaperStyle.init(rawValue:)) else { return .keepOpen }
            return await self.applyWallpaper(style: style, reshuffle: false)
        }
    }

    func shuffleWallpaperAction() -> ThemeAction {
        ThemeAction(
            id: ActionID(module: "theme", name: "shuffleWallpaper"),
            title: "Shuffle Wallpaper",
            subtitle: "A new variation of the current generated wallpaper",
            iconName: "shuffle",
            relevanceScore: 0.7,
            keywords: ["wallpaper", "background", "shuffle", "random", "new", "theme"]
        ) { _ in
            await self.applyWallpaper(style: nil, reshuffle: true)
        }
    }
}

extension ResolvedTheme {
    /// The same theme with its wallpaper image dropped, so a generated one is used.
    func generatingWallpaper() -> ResolvedTheme {
        ResolvedTheme(
            name: name, slug: slug, palette: palette, wallpaper: nil, wallpaperStyle: wallpaperStyle, icon: icon,
            subtitle: subtitle, keywords: keywords, macosAccent: macosAccent, macStyle: macStyle,
            appOverrides: appOverrides, source: source
        )
    }
}
