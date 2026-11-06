import AppKit
import Foundation
import OSLog

private let log = Log.module("theme")

/// Private SkyLight API behind System Settings › Appearance › Icon & widget style and
/// "Icon, widget & folder color" (macOS 26+): `SLSIconAppearanceConfiguration`, the object
/// the Appearance pane saves, so changes are live. Resolved dynamically; every entry
/// point degrades to a no-op when the class or a selector is missing.
@MainActor
enum IconAppearance {
    struct SavedTint: Sendable {
        let tintName: UInt32
        let custom: ThemeColor?
        let namePreference: String?
        let colorPreference: String?
    }

    private static let nameKey = "AppleIconAppearanceTintColor"
    private static let colorKey = "AppleIconAppearanceCustomTintColor"
    private static let themeKey = "AppleIconAppearanceTheme"

    /// Order of SkyLight's tint-name table; the enum value is the index + 1 (0 = none).
    private static let tintNames = ["Hardware", "Red", "Orange", "Yellow", "Green", "Blue",
                                    "Purple", "Pink", "Graphite", "Other"]
    /// Order of SkyLight's icon theme table; here the enum value is the index itself.
    /// Measured on macOS 27.2 from the names SkyLight saves: 0 RegularAutomatic,
    /// 2 RegularDark, 4 ClearLight, 7 TintedLight, 8 TintedDark. 1, RegularLight, is the
    /// default "Default" style: saving it removes the preference, and SkyLight falls back
    /// to it for values out of range.
    static let themeNames = ["RegularAutomatic", "RegularLight", "RegularDark",
                             "ClearAutomatic", "ClearLight", "ClearDark",
                             "TintedAutomatic", "TintedLight", "TintedDark"]

    private typealias GetU32 = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias SetU32 = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias GetColor = @convention(c) (AnyObject, Selector) -> Unmanaged<CGColor>?
    private typealias SetColor = @convention(c) (AnyObject, Selector, CGColor?) -> Void
    private typealias Save = @convention(c) (AnyObject, Selector) -> Void

    // MARK: - Tint color

    static func applyTint(_ color: ThemeColor) -> Bool {
        guard let config = fetch(),
              numberingIsVerified(config, preference: nameKey, names: tintNames, offset: 1,
                                  getter: "iconTintColorName"),
              let other = tintNames.firstIndex(of: "Other")
        else { return false }
        // The preferences behind the setting (format from SkyLight's own string table),
        // so the color also holds across logins if the live update doesn't take.
        SystemPreferences.set("Other", forKey: nameKey)
        SystemPreferences.set(
            String(format: "%f %f %f %f", color.red, color.green, color.blue, 1.0), forKey: colorKey
        )
        return writeTint(config, tintName: UInt32(other + 1), custom: color)
    }

    static func currentTint() -> SavedTint? {
        guard let config = fetch(),
              let tintName = call(config, "iconTintColorName", as: GetU32.self)
        else { return nil }
        let customColor = call(config, "otherIconTintColor", as: GetColor.self)?.takeUnretainedValue()
        let custom = customColor
            .flatMap { NSColor(cgColor: $0) }
            .flatMap(ThemeColor.init(nsColor:))
        return SavedTint(
            tintName: tintName,
            custom: custom,
            namePreference: SystemPreferences.value(nameKey) as? String,
            colorPreference: SystemPreferences.value(colorKey) as? String
        )
    }

    static func restoreTint(_ saved: SavedTint) {
        SystemPreferences.set(saved.namePreference, forKey: nameKey)
        SystemPreferences.set(saved.colorPreference, forKey: colorKey)
        guard let config = fetch() else { return }
        _ = writeTint(config, tintName: saved.tintName, custom: saved.custom)
    }

    // MARK: - Icon & widget style

    /// The current style; nil before macOS 26 or if SkyLight numbers styles differently.
    static func style() -> IconStyle? {
        guard let config = fetch(),
              numberingIsVerified(config, preference: themeKey, names: themeNames, offset: 0,
                                  getter: "iconAppearanceTheme"),
              let value = call(config, "iconAppearanceTheme", as: GetU32.self),
              value < themeNames.count
        else { return nil }
        return IconStyle(systemName: themeNames[Int(value)])
    }

    /// Saves the style (SkyLight writes `AppleIconAppearanceTheme` itself) and reads it
    /// back. Tinted styles use the current tint color.
    static func setStyle(_ style: IconStyle) -> Bool {
        guard let index = themeNames.firstIndex(of: style.systemName), let config = fetch(),
              numberingIsVerified(config, preference: themeKey, names: themeNames, offset: 0,
                                  getter: "iconAppearanceTheme"),
              let setTheme = function(config, "setIconAppearanceTheme:", as: SetU32.self),
              let save = function(config, "save", as: Save.self)
        else { return false }
        setTheme(config, NSSelectorFromString("setIconAppearanceTheme:"), UInt32(index))
        save(config, NSSelectorFromString("save"))
        return self.style() == style
    }

    // MARK: - SkyLight

    private static func writeTint(_ config: NSObject, tintName: UInt32, custom: ThemeColor?) -> Bool {
        guard let setName = function(config, "setIconTintColorName:", as: SetU32.self),
              let setColor = function(config, "setOtherIconTintColor:", as: SetColor.self),
              let save = function(config, "save", as: Save.self)
        else { return false }
        setColor(config, NSSelectorFromString("setOtherIconTintColor:"), custom?.cgColor)
        setName(config, NSSelectorFromString("setIconTintColorName:"), tintName)
        save(config, NSSelectorFromString("save"))
        return true
    }

    /// A fresh copy of the saved configuration, so the folder color and icon style
    /// targets each change only their own field.
    private static func fetch() -> NSObject? {
        guard dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) != nil,
              let type = NSClassFromString("SLSIconAppearanceConfiguration") as? NSObject.Type
        else { return nil }
        let selector = NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")
        guard type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// The numbering is inferred from SkyLight's string tables. When the preference
    /// holds a name, cross-check it against the configuration before relying on it, and
    /// refuse if this macOS numbers them differently.
    private static func numberingIsVerified(
        _ config: NSObject, preference: String, names: [String], offset: UInt32, getter: String
    ) -> Bool {
        guard let name = SystemPreferences.value(preference) as? String,
              let index = names.firstIndex(of: name)
        else { return true }
        let matches = call(config, getter, as: GetU32.self) == UInt32(index) + offset
        if !matches { log.warning("Unrecognized \(preference, privacy: .public) numbering; leaving it alone") }
        return matches
    }

    private static func function<T>(_ object: NSObject, _ name: String, as type: T.Type) -> T? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return unsafeBitCast(object.method(for: selector), to: type)
    }

    private static func call(_ object: NSObject, _ name: String, as type: GetU32.Type) -> UInt32? {
        function(object, name, as: type).map { $0(object, NSSelectorFromString(name)) }
    }

    private static func call(_ object: NSObject, _ name: String, as type: GetColor.Type) -> Unmanaged<CGColor>? {
        function(object, name, as: type).flatMap { $0(object, NSSelectorFromString(name)) }
    }
}
