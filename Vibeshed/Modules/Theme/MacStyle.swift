import Foundation

/// What a theme sets in System Settings beyond its colors: Liquid Glass, the icon & widget
/// style and the menu bar background. A nil field is no opinion: the user's own setting
/// stays, or comes back if an earlier theme changed it (see `ThemedSystemSetting`).
struct MacStyle: Sendable, Equatable {
    /// Liquid Glass tint, from 0 (clear) to 1 (tinted).
    var glass: Double?
    var iconStyle: IconStyle?
    var menuBarBackground: MenuBarBackground?

    var isEmpty: Bool {
        glass == nil && iconStyle == nil && menuBarBackground == nil
    }

    /// Parses a theme definition's `macos…` settings.
    init(_ definition: ThemeDefinition) throws {
        if let text = definition.macosGlass {
            guard let value = Self.glass(text) else { throw MacStyleError.glass(text) }
            glass = value
        }
        if let text = definition.macosIconStyle {
            guard let style = IconStyle(text) else { throw MacStyleError.iconStyle(text) }
            iconStyle = style
        }
        menuBarBackground = definition.macosMenuBarBackground
    }

    init(glass: Double? = nil, iconStyle: IconStyle? = nil, menuBarBackground: MenuBarBackground? = nil) {
        self.glass = glass
        self.iconStyle = iconStyle
        self.menuBarBackground = menuBarBackground
    }

    /// `clear`, `tinted`, or a tint amount from 0 to 1.
    static func glass(_ text: String) -> Double? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "clear": 0
        case "tinted": 1
        case let number: Double(number).flatMap { (0 ... 1).contains($0) ? $0 : nil }
        }
    }

    /// For keeping a generated theme's style in defaults, in config's spelling.
    var stored: [String: String] {
        var values: [String: String] = [:]
        values["glass"] = glass.map { String($0) }
        values["iconStyle"] = iconStyle?.configName
        values["menuBarBackground"] = menuBarBackground?.rawValue
        return values
    }

    init(stored: [String: String]) {
        glass = stored["glass"].flatMap(Self.glass)
        iconStyle = stored["iconStyle"].flatMap { IconStyle($0) }
        menuBarBackground = stored["menuBarBackground"].flatMap(MenuBarBackground.init(rawValue:))
    }

    /// For the theme preview: what the theme changes, e.g. "Tinted icons · Glass 40%".
    var summary: String? {
        var parts: [String] = []
        if let iconStyle { parts.append(iconStyle.displayName) }
        if let glass {
            let percent = Int((glass * 100).rounded())
            parts.append(glass == 0 ? "Clear glass" : glass == 1 ? "Tinted glass" : "Glass \(percent)% tinted")
        }
        if let menuBarBackground {
            parts.append(menuBarBackground == .show ? "Menu bar background" : "No menu bar background")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum MacStyleError: LocalizedError {
    case glass(String)
    case iconStyle(String)

    var errorDescription: String? {
        switch self {
        case let .glass(text): "macosGlass '\(text)' is not clear, tinted or a number from 0 to 1"
        case let .iconStyle(text):
            "macosIconStyle '\(text)' is not one of \(IconStyle.configNames.joined(separator: ", "))"
        }
    }
}

/// System Settings › Appearance › Icon & widget style (macOS 26+): a look in a light,
/// dark or automatic (follows the appearance) variant. macOS's "Default" is regular icons
/// in the light variant; tinted icons take the "Icon, widget & folder color", which the
/// `folders` target sets to the theme's folder color.
struct IconStyle: Sendable, Equatable {
    enum Look: String, CaseIterable, Sendable {
        case regular = "Regular"
        case clear = "Clear"
        case tinted = "Tinted"
    }

    enum Variant: String, CaseIterable, Sendable {
        case automatic = "Automatic"
        case light = "Light"
        case dark = "Dark"
    }

    let look: Look
    let variant: Variant

    init(_ look: Look, _ variant: Variant = .automatic) {
        self.look = look
        self.variant = variant
    }

    /// macOS's own default.
    static let systemDefault = IconStyle(.regular, .light)

    /// Config names: `default` (macOS's), `dark`, `auto` (regular icons that go dark in
    /// Dark mode), `clear` and `tinted` (following the appearance), and `clear-light` …
    /// `tinted-dark` for one pinned to a variant.
    init?(_ text: String) {
        let words = text.lowercased().split { $0 == "-" || $0 == " " || $0 == "_" }.map(String.init)
        switch words {
        case ["default"], ["light"]: self = .systemDefault
        case ["dark"]: self.init(.regular, .dark)
        case ["auto"], ["automatic"]: self.init(.regular, .automatic)
        default:
            guard words.count <= 2,
                  let look = Look.allCases.first(where: { $0.rawValue.lowercased() == words.first })
            else { return nil }
            // `clear-dark`, `tinted-auto`, `regular-light`, …
            let variantName = words.count == 2 ? words[1] : "automatic"
            let variant = Variant.allCases.first { $0.rawValue.lowercased().hasPrefix(variantName) }
            guard let variant, variantName.count >= 4 else { return nil }
            self.init(look, variant)
        }
    }

    /// SkyLight's name for it: `RegularLight`, `ClearDark`, …
    var systemName: String {
        look.rawValue + variant.rawValue
    }

    init?(systemName: String) {
        guard let look = Look.allCases.first(where: { systemName.hasPrefix($0.rawValue) }),
              let variant = Variant(rawValue: String(systemName.dropFirst(look.rawValue.count)))
        else { return nil }
        self.init(look, variant)
    }

    /// The name config uses for it (see `init?(_:)`).
    var configName: String {
        switch (look, variant) {
        case (.regular, .light): "default"
        case (.regular, .dark): "dark"
        case (.regular, .automatic): "auto"
        case (_, .automatic): look.rawValue.lowercased()
        default: "\(look.rawValue.lowercased())-\(variant.rawValue.lowercased())"
        }
    }

    var displayName: String {
        switch (look, variant) {
        case (.regular, .light): "Default icons"
        case (.regular, .dark): "Dark icons"
        case (.regular, .automatic): "Icons dark in Dark mode"
        case (_, .automatic): "\(look.rawValue) icons"
        default: "\(look.rawValue) \(variant.rawValue.lowercased()) icons"
        }
    }

    static let configNames = ["default", "dark", "auto", "clear", "clear-light", "clear-dark",
                              "tinted", "tinted-light", "tinted-dark"]
}

/// System Settings › Menu Bar › "Show menu bar background" (macOS 26+). Config takes
/// `true`/`false` as well as `show`/`hide`.
enum MenuBarBackground: String, Codable, Sendable {
    case show
    case hide

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let shown = try? container.decode(Bool.self) {
            self = shown ? .show : .hide
            return
        }
        let text = try container.decode(String.self).lowercased()
        switch text {
        case "show", "true", "yes", "on": self = .show
        case "hide", "false", "no", "off": self = .hide
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "macosMenuBarBackground '\(text)' is not true/false (show/hide)"
            )
        }
    }
}
