import Foundation

struct ThemeConfig: Codable, Sendable, Equatable {
    /// Themes defined in config. A theme whose name matches a built-in (or a themes-directory
    /// theme) replaces it; `base:` inherits another theme's colors and overrides a few.
    var themes: [ThemeDefinition] = []

    /// List the built-in palettes (Tokyo Night, Catppuccin, Gruvbox, …).
    var includeBuiltInThemes = true

    /// Omarchy-style theme directories: each `<dir>/colors.toml` becomes a theme, with an
    /// optional `backgrounds/` image folder and `light.mode` marker. Missing dir = none.
    var themesDirectory = "~/.config/vibeshed/themes"

    /// Targets to apply, by id (see `ThemeTargetID`). `nil` = the defaults (everything
    /// except `github`, which rewrites a server-side account setting).
    var targets: [String]?

    /// Apply the highlighted theme while browsing `theme/switch`; Escape reverts.
    var livePreview = true

    /// Generate a wallpaper from the palette for themes that don't ship an image.
    var generateWallpapers = true

    /// Default style for generated wallpapers: a `WallpaperStyle` name or `auto` (a stable
    /// pick per theme). A style chosen with `theme/wallpaperStyle` takes precedence.
    var wallpaperStyle = WallpaperStyle.glow.rawValue

    /// Fine film grain texture on generated wallpapers.
    var wallpaperGrain = true

    /// Make the "Vibeshed" iTerm profile the default, so new windows and iTerm restarts
    /// keep the theme. `false` hands the default back to the profile it replaced.
    var itermDefaultProfile = true

    /// Make the "Vibeshed" Terminal profile the default and startup profile, so new windows
    /// and Terminal restarts keep the theme. `false` hands those back to your own profiles.
    var terminalDefaultProfile = true

    /// Folders that get a palette-tinted custom icon (on top of the system-wide folder color).
    var folders: [String] = []

    /// Omarchy-compatible `{{ key }}` templates rendered on every apply.
    var templates: [ThemeTemplateConfig] = []

    /// Shell commands run after every apply, with `VIBESHED_THEME*` / `VIBESHED_COLOR_*` env vars.
    var hooks: [String] = []

    /// Font families to offer in `theme/switchFont` besides the curated coding fonts
    /// (listed when installed).
    var fonts: [String] = []

    /// VS Code-family editors: display name → Application Support folder
    /// (nil = VS Code, Insiders, Cursor, Windsurf, VSCodium).
    var vscodeVariants: [String: String]?

    /// JetBrains IDE tags to theme (nil = all detected).
    var jetbrainsIDEs: Set<String>?

    /// Action name suffixes to expose (nil = all).
    var enabledActions: Set<String>?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThemeConfig()
        themes = try container.decodeIfPresent([ThemeDefinition].self, forKey: .themes) ?? defaults.themes
        includeBuiltInThemes = try container.decodeIfPresent(Bool.self, forKey: .includeBuiltInThemes)
            ?? defaults.includeBuiltInThemes
        themesDirectory = try container.decodeIfPresent(String.self, forKey: .themesDirectory)
            ?? defaults.themesDirectory
        targets = try container.decodeIfPresent([String].self, forKey: .targets)
        livePreview = try container.decodeIfPresent(Bool.self, forKey: .livePreview) ?? defaults.livePreview
        generateWallpapers = try container.decodeIfPresent(Bool.self, forKey: .generateWallpapers)
            ?? defaults.generateWallpapers
        wallpaperStyle = try container.decodeIfPresent(String.self, forKey: .wallpaperStyle)
            ?? defaults.wallpaperStyle
        wallpaperGrain = try container.decodeIfPresent(Bool.self, forKey: .wallpaperGrain) ?? defaults.wallpaperGrain
        itermDefaultProfile = try container.decodeIfPresent(Bool.self, forKey: .itermDefaultProfile)
            ?? defaults.itermDefaultProfile
        terminalDefaultProfile = try container.decodeIfPresent(Bool.self, forKey: .terminalDefaultProfile)
            ?? defaults.terminalDefaultProfile
        folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? defaults.folders
        templates = try container.decodeIfPresent([ThemeTemplateConfig].self, forKey: .templates)
            ?? defaults.templates
        hooks = try container.decodeIfPresent([String].self, forKey: .hooks) ?? defaults.hooks
        fonts = try container.decodeIfPresent([String].self, forKey: .fonts) ?? defaults.fonts
        vscodeVariants = try container.decodeIfPresent([String: String].self, forKey: .vscodeVariants)
        jetbrainsIDEs = try container.decodeIfPresent(Set<String>.self, forKey: .jetbrainsIDEs)
        enabledActions = try container.decodeIfPresent(Set<String>.self, forKey: .enabledActions)
    }

    /// The effective, validated target set.
    var enabledTargets: Set<ThemeTargetID> {
        guard let targets else { return ThemeTargetID.defaults }
        return Set(targets.compactMap(ThemeTargetID.init(rawValue:)))
    }
}

/// One palette theme. Colors use Omarchy `colors.toml` key names; only `background`,
/// `foreground` and the six base hues are required — everything else is derived.
struct ThemeDefinition: Codable, Sendable, Equatable {
    var name: String
    /// Another theme (by name) to inherit colors, mode, wallpaper and app overrides from.
    var base: String?
    var mode: ThemeMode?
    /// The theme (by name) of the opposite mode that this one switches to when the system
    /// does. Declaring it on either side links both. Built-in pairs: `BuiltInThemes.pairs`.
    var pair: String?
    var colors: [String: String] = [:]
    /// Image file, or a folder of images (the first, sorted, is used).
    var wallpaper: String?
    /// Generated wallpaper style for this theme, when it has no image (overrides the default).
    var wallpaperStyle: String?
    var icon: String?
    var subtitle: String?
    var keywords: [String] = []
    /// macOS accent color name (Blue, Purple, Pink, Red, Orange, Yellow, Green, Graphite,
    /// Multicolor). Default: the named color nearest the palette's accent hue.
    var macosAccent: String?
    /// Use an existing app theme instead of generating one, by target id:
    /// `vscode`, `zed`, `jetbrains`, `iterm`, `ghostty`, `terminal`, `neovim`, `claude`, `github`.
    var apps: [String: String] = [:]

    init(
        name: String,
        base: String? = nil,
        mode: ThemeMode? = nil,
        pair: String? = nil,
        colors: [String: String] = [:],
        wallpaper: String? = nil,
        wallpaperStyle: String? = nil,
        icon: String? = nil,
        subtitle: String? = nil,
        keywords: [String] = [],
        macosAccent: String? = nil,
        apps: [String: String] = [:]
    ) {
        self.name = name
        self.base = base
        self.mode = mode
        self.pair = pair
        self.colors = colors
        self.wallpaper = wallpaper
        self.wallpaperStyle = wallpaperStyle
        self.icon = icon
        self.subtitle = subtitle
        self.keywords = keywords
        self.macosAccent = macosAccent
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        mode = try container.decodeIfPresent(ThemeMode.self, forKey: .mode)
        pair = try container.decodeIfPresent(String.self, forKey: .pair)
        colors = try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        wallpaper = try container.decodeIfPresent(String.self, forKey: .wallpaper)
        wallpaperStyle = try container.decodeIfPresent(String.self, forKey: .wallpaperStyle)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        macosAccent = try container.decodeIfPresent(String.self, forKey: .macosAccent)
        apps = try container.decodeIfPresent([String: String].self, forKey: .apps) ?? [:]
    }
}

struct ThemeTemplateConfig: Codable, Sendable, Equatable {
    /// Template file with `{{ key }}`, `{{ key_strip }}`, `{{ key_rgb }}` and
    /// `{{ mix a b 30% }}` placeholders.
    var source: String
    /// Where the rendered file is written.
    var target: String
    /// Shell command run after writing, e.g. to make the app reload its config.
    var reload: String?
    /// Also render while live-previewing (only for apps that reload cheaply).
    var preview = false

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
        reload = try container.decodeIfPresent(String.self, forKey: .reload)
        preview = try container.decodeIfPresent(Bool.self, forKey: .preview) ?? false
    }
}

/// Everything a theme can be applied to. Raw values are the config names.
enum ThemeTargetID: String, CaseIterable, Sendable {
    case appearance
    case accent
    case folders
    case pointer
    case wallpaper
    case iterm
    case ghostty
    case terminal
    case vscode
    case zed
    case jetbrains
    case neovim
    case claude
    case bat
    case lsd
    case micro
    case btop
    case github
    case templates
    case hooks

    static let defaults: Set<ThemeTargetID> = Set(allCases).subtracting([.github])
}

/// Keys accepted under a theme's `apps:` map.
enum ThemeAppOverride {
    static let keys: Set<String> = [
        "vscode", "zed", "jetbrains", "iterm", "ghostty", "terminal", "neovim", "claude", "github",
    ]
}
