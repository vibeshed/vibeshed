import Foundation

/// Palettes that ship with Vibeshed. Values follow each project's published terminal
/// palette; keys are Omarchy `colors.toml` names so any of these can be used as a
/// `base:` and tweaked in config. The hand-tuned core set lives here; the community and
/// Omarchy sets are generated (see `scripts/generate-builtin-themes.py`).
enum BuiltInThemes {
    /// Every built-in theme, alphabetically — so a family (Catppuccin Frappé, Latte,
    /// Macchiato, Mocha) sits together in `theme/switch`.
    static let all: [ThemeDefinition] = (core + communityDark + communityLight + omarchy + retro + classicMac + vintage)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static let core: [ThemeDefinition] = [
        tokyoNight, catppuccinMocha, catppuccinLatte, gruvbox, nord, everforest,
        rosePine, kanagawa, dracula, oneDark, solarizedLight, flexokiLight,
    ]

    /// Themes that are one design's light and dark halves, and so follow the system's mode.
    /// A family's dark variants all pair with its one light theme. Everything else is
    /// specifically light or dark.
    static let pairs: [(light: String, darks: [String])] = [
        ("Ayu Light", ["Ayu Dark", "Ayu Mirage"]),
        ("Catppuccin Latte", ["Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappé"]),
        ("Dawnfox", ["Nightfox", "Carbonfox"]),
        ("Everforest Light", ["Everforest"]),
        ("Flexoki Light", ["Flexoki Dark"]),
        ("GitHub Light", ["GitHub Dark", "GitHub Dark Dimmed"]),
        ("Gruvbox Light", ["Gruvbox"]),
        ("Kanagawa Lotus", ["Kanagawa", "Kanagawa Dragon"]),
        ("Melange Light", ["Melange Dark"]),
        ("Nord Light", ["Nord"]),
        ("One Light", ["One Dark"]),
        ("Rosé Pine Dawn", ["Rosé Pine", "Rosé Pine Moon"]),
        ("Solarized Light", ["Solarized Dark"]),
        ("Tokyo Night Day", ["Tokyo Night", "Tokyo Night Storm", "Tokyo Night Moon"]),
    ]

    static let tokyoNight = ThemeDefinition(
        name: "Tokyo Night",
        mode: .dark,
        colors: [
            "background": "#1a1b26", "foreground": "#a9b1d6", "bright_foreground": "#c0caf5",
            "accent": "#7aa2f7", "cursor": "#c0caf5", "selection_background": "#283457",
            "muted": "#565f89", "color0": "#15161e", "color8": "#414868",
            "lighter_background": "#24283b", "dark_background": "#16161e", "darker_background": "#0e0e14",
            "red": "#f7768e", "orange": "#ff9e64", "yellow": "#e0af68", "green": "#9ece6a",
            "cyan": "#7dcfff", "blue": "#7aa2f7", "magenta": "#bb9af7",
            "bright_red": "#ff899d", "bright_yellow": "#faba4a", "bright_green": "#9fe044",
            "bright_cyan": "#a4daff", "bright_blue": "#8db0ff", "bright_magenta": "#c7a9ff",
        ],
        icon: "moon.stars",
        keywords: ["tokyonight", "folke", "blue"]
    )

    static let catppuccinMocha = ThemeDefinition(
        name: "Catppuccin Mocha",
        mode: .dark,
        colors: [
            "background": "#1e1e2e", "foreground": "#cdd6f4", "bright_foreground": "#cdd6f4",
            "accent": "#cba6f7", "cursor": "#f5e0dc", "selection_background": "#45475a",
            "muted": "#7f849c", "color0": "#45475a", "color7": "#bac2de", "color8": "#585b70",
            "color15": "#a6adc8", "lighter_background": "#313244", "dark_background": "#181825",
            "darker_background": "#11111b",
            "red": "#f38ba8", "orange": "#fab387", "yellow": "#f9e2af", "green": "#a6e3a1",
            "cyan": "#94e2d5", "blue": "#89b4fa", "magenta": "#f5c2e7",
        ],
        icon: "cup.and.saucer",
        keywords: ["catppuccin", "mauve", "pastel"]
    )

    static let catppuccinLatte = ThemeDefinition(
        name: "Catppuccin Latte",
        mode: .light,
        colors: [
            "background": "#eff1f5", "foreground": "#4c4f69", "bright_foreground": "#4c4f69",
            "accent": "#8839ef", "cursor": "#dc8a78", "selection_background": "#acb0be",
            "muted": "#8c8fa1", "color0": "#5c5f77", "color7": "#acb0be", "color8": "#6c6f85",
            "color15": "#bcc0cc", "lighter_background": "#e6e9ef", "dark_background": "#dce0e8",
            "darker_background": "#ccd0da",
            "red": "#d20f39", "orange": "#fe640b", "yellow": "#df8e1d", "green": "#40a02b",
            "cyan": "#179299", "blue": "#1e66f5", "magenta": "#ea76cb",
            "bright_red": "#d20f39", "bright_yellow": "#df8e1d", "bright_green": "#40a02b",
            "bright_cyan": "#179299", "bright_blue": "#1e66f5", "bright_magenta": "#ea76cb",
        ],
        icon: "mug",
        keywords: ["catppuccin", "light", "pastel"]
    )

    static let gruvbox = ThemeDefinition(
        name: "Gruvbox",
        mode: .dark,
        colors: [
            "background": "#282828", "foreground": "#ebdbb2", "bright_foreground": "#fbf1c7",
            "accent": "#fe8019", "cursor": "#ebdbb2", "selection_background": "#504945",
            "muted": "#928374", "color7": "#a89984", "color8": "#928374", "color15": "#ebdbb2",
            "lighter_background": "#3c3836", "dark_background": "#1d2021", "darker_background": "#141617",
            "red": "#cc241d", "orange": "#d65d0e", "yellow": "#d79921", "green": "#98971a",
            "cyan": "#689d6a", "blue": "#458588", "magenta": "#b16286",
            "bright_red": "#fb4934", "bright_yellow": "#fabd2f", "bright_green": "#b8bb26",
            "bright_cyan": "#8ec07c", "bright_blue": "#83a598", "bright_magenta": "#d3869b",
        ],
        icon: "flame",
        keywords: ["gruvbox", "retro", "warm"]
    )

    static let nord = ThemeDefinition(
        name: "Nord",
        mode: .dark,
        colors: [
            "background": "#2e3440", "foreground": "#d8dee9", "bright_foreground": "#eceff4",
            "accent": "#88c0d0", "cursor": "#d8dee9", "selection_background": "#434c5e",
            "muted": "#616e88", "color0": "#3b4252", "color7": "#e5e9f0", "color8": "#4c566a",
            "lighter_background": "#3b4252", "dark_background": "#272c36", "darker_background": "#20242c",
            "red": "#bf616a", "orange": "#d08770", "yellow": "#ebcb8b", "green": "#a3be8c",
            "cyan": "#88c0d0", "blue": "#81a1c1", "magenta": "#b48ead",
            "bright_red": "#bf616a", "bright_yellow": "#ebcb8b", "bright_green": "#a3be8c",
            "bright_cyan": "#8fbcbb", "bright_blue": "#81a1c1", "bright_magenta": "#b48ead",
        ],
        icon: "snowflake",
        keywords: ["nord", "arctic", "cool"]
    )

    static let everforest = ThemeDefinition(
        name: "Everforest",
        mode: .dark,
        colors: [
            "background": "#2d353b", "foreground": "#d3c6aa", "accent": "#a7c080",
            "cursor": "#d3c6aa", "selection_background": "#543a48", "muted": "#859289",
            "color0": "#475258", "color8": "#859289", "lighter_background": "#343f44",
            "dark_background": "#232a2e", "darker_background": "#1e2326",
            "red": "#e67e80", "orange": "#e69875", "yellow": "#dbbc7f", "green": "#a7c080",
            "cyan": "#83c092", "blue": "#7fbbb3", "magenta": "#d699b6",
        ],
        icon: "tree",
        keywords: ["everforest", "forest", "green"]
    )

    static let rosePine = ThemeDefinition(
        name: "Rosé Pine",
        mode: .dark,
        colors: [
            "background": "#191724", "foreground": "#e0def4", "accent": "#ebbcba",
            "cursor": "#e0def4", "selection_background": "#403d52", "muted": "#6e6a86",
            "color0": "#26233a", "color8": "#6e6a86", "lighter_background": "#1f1d2e",
            "dark_background": "#15131f", "darker_background": "#100e18",
            "red": "#eb6f92", "yellow": "#f6c177", "green": "#31748f", "cyan": "#ebbcba",
            "blue": "#9ccfd8", "magenta": "#c4a7e7",
        ],
        icon: "camera.macro",
        keywords: ["rose", "pine", "rosepine", "pink"]
    )

    static let kanagawa = ThemeDefinition(
        name: "Kanagawa",
        mode: .dark,
        colors: [
            "background": "#1f1f28", "foreground": "#dcd7ba", "accent": "#7e9cd8",
            "cursor": "#c8c093", "selection_background": "#2d4f67", "muted": "#727169",
            "color0": "#16161d", "color7": "#c8c093", "color8": "#727169",
            "lighter_background": "#2a2a37", "dark_background": "#16161d", "darker_background": "#101015",
            "red": "#c34043", "orange": "#ffa066", "yellow": "#c0a36e", "green": "#76946a",
            "cyan": "#6a9589", "blue": "#7e9cd8", "magenta": "#957fb8",
            "bright_red": "#e82424", "bright_yellow": "#e6c384", "bright_green": "#98bb6c",
            "bright_cyan": "#7aa89f", "bright_blue": "#7fb4ca", "bright_magenta": "#938aa9",
        ],
        icon: "water.waves",
        keywords: ["kanagawa", "wave", "japanese"]
    )

    static let dracula = ThemeDefinition(
        name: "Dracula",
        mode: .dark,
        colors: [
            "background": "#282a36", "foreground": "#f8f8f2", "bright_foreground": "#ffffff",
            "accent": "#bd93f9", "cursor": "#f8f8f2", "selection_background": "#44475a",
            "muted": "#6272a4", "color0": "#21222c", "color8": "#6272a4",
            "lighter_background": "#343746", "dark_background": "#21222c", "darker_background": "#191a21",
            "red": "#ff5555", "orange": "#ffb86c", "yellow": "#f1fa8c", "green": "#50fa7b",
            "cyan": "#8be9fd", "blue": "#bd93f9", "magenta": "#ff79c6",
            "bright_red": "#ff6e6e", "bright_yellow": "#ffffa5", "bright_green": "#69ff94",
            "bright_cyan": "#a4ffff", "bright_blue": "#d6acff", "bright_magenta": "#ff92df",
        ],
        icon: "theatermasks",
        keywords: ["dracula", "purple", "vampire"]
    )

    static let oneDark = ThemeDefinition(
        name: "One Dark",
        mode: .dark,
        colors: [
            "background": "#282c34", "foreground": "#abb2bf", "bright_foreground": "#ffffff",
            "accent": "#61afef", "cursor": "#528bff", "selection_background": "#3e4451",
            "muted": "#5c6370", "color0": "#1e2127", "color8": "#5c6370",
            "lighter_background": "#2c313a", "dark_background": "#21252b", "darker_background": "#1b1e23",
            "red": "#e06c75", "orange": "#d19a66", "yellow": "#e5c07b", "green": "#98c379",
            "cyan": "#56b6c2", "blue": "#61afef", "magenta": "#c678dd",
        ],
        icon: "atom",
        keywords: ["onedark", "atom"]
    )

    static let solarizedLight = ThemeDefinition(
        name: "Solarized Light",
        mode: .light,
        colors: [
            "background": "#fdf6e3", "foreground": "#657b83", "bright_foreground": "#586e75",
            "accent": "#268bd2", "cursor": "#586e75", "selection_background": "#eee8d5",
            "selection_foreground": "#586e75", "muted": "#93a1a1",
            "color0": "#073642", "color7": "#eee8d5", "color8": "#002b36", "color15": "#fdf6e3",
            "lighter_background": "#eee8d5", "dark_background": "#eee8d5", "darker_background": "#e6dfcb",
            "red": "#dc322f", "orange": "#cb4b16", "yellow": "#b58900", "green": "#859900",
            "cyan": "#2aa198", "blue": "#268bd2", "magenta": "#d33682",
            "bright_red": "#dc322f", "bright_yellow": "#b58900", "bright_green": "#859900",
            "bright_cyan": "#2aa198", "bright_blue": "#268bd2", "bright_magenta": "#6c71c4",
        ],
        icon: "sun.max",
        keywords: ["solarized", "light"]
    )

    static let flexokiLight = ThemeDefinition(
        name: "Flexoki Light",
        mode: .light,
        colors: [
            "background": "#fffcf0", "foreground": "#100f0f", "accent": "#205ea6",
            "cursor": "#100f0f", "selection_background": "#cecdc3", "muted": "#6f6e69",
            "color0": "#100f0f", "color7": "#6f6e69", "color8": "#b7b5ac", "color15": "#cecdc3",
            "lighter_background": "#f2f0e5", "dark_background": "#f2f0e5", "darker_background": "#e6e4d9",
            "red": "#af3029", "orange": "#bc5215", "yellow": "#ad8301", "green": "#66800b",
            "cyan": "#24837b", "blue": "#205ea6", "magenta": "#a02f6f",
            "bright_red": "#d14d41", "bright_yellow": "#d0a215", "bright_green": "#879a39",
            "bright_cyan": "#3aa99f", "bright_blue": "#4385be", "bright_magenta": "#ce5d97",
        ],
        icon: "book",
        keywords: ["flexoki", "paper", "light"]
    )
}
