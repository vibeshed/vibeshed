import Foundation

/// The System Settings that are part of a built-in theme's look (see `MacStyle`). Kept here
/// rather than in each definition so the generated community and Omarchy files stay as
/// `scripts/generate-builtin-themes.py` writes them. Every other built-in leaves your own
/// Liquid Glass, icon style and menu bar background alone.
extension BuiltInThemes {
    static func withMacStyle(_ definition: ThemeDefinition) -> ThemeDefinition {
        macStyles[definition.name].map(definition.with) ?? definition
    }

    static let macStyles: [String: MacStyle] = {
        var styles: [String: MacStyle] = [:]
        // Classic desktops drew solid chrome: a menu bar (or deskbar, taskbar) with a
        // background, and nothing see-through, so the glass is as tinted as it goes.
        for theme in retro + classicMac + vintage {
            styles[theme.name] = MacStyle(glass: 1, menuBarBackground: .show)
        }
        // Colorless palettes keep the Dock and desktop colorless too.
        for name in ["Vantablack", "White", "Solitude"] {
            styles[name] = MacStyle(iconStyle: IconStyle(.clear))
        }
        // One-hue palettes (Hackerman's phosphor green, Matte Black's orange, Lumon's
        // terminal blue, Osaka Jade): icons tinted in it, via the folder color.
        for name in ["Hackerman", "Lumon", "Matte Black", "Osaka Jade"] {
            styles[name] = MacStyle(iconStyle: IconStyle(.tinted))
        }
        return styles
    }()
}

extension ThemeDefinition {
    /// The definition with `style`'s opinions in its `macos…` fields (others kept).
    func with(_ style: MacStyle) -> ThemeDefinition {
        var copy = self
        copy.macosGlass = style.glass.map { String($0) } ?? macosGlass
        copy.macosIconStyle = style.iconStyle?.configName ?? macosIconStyle
        copy.macosMenuBarBackground = style.menuBarBackground ?? macosMenuBarBackground
        return copy
    }
}
