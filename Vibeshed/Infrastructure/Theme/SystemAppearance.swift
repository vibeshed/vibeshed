import AppKit
import Foundation

/// macOS's light/dark state and its Auto setting (System Settings › Appearance).
enum SystemAppearance {
    @MainActor
    static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Whether the system switches between light and dark on its schedule. SkyLight owns
    /// this: writing `AppleInterfaceStyleSwitchesAutomatically` changes what the preference
    /// reads but not what the system does.
    static var switchesAutomatically: Bool {
        typealias Getter = @convention(c) () -> Bool
        return skyLightFunction("SLSGetAppearanceThemeSwitchesAutomatically", as: Getter.self)?() ?? false
    }

    /// Turning it on moves the system to the schedule's mode about a second later, unless
    /// a mode is set before then. Returns false if SkyLight no longer offers the call.
    @discardableResult
    static func setSwitchesAutomatically(_ enabled: Bool) -> Bool {
        typealias Setter = @convention(c) (Bool) -> Void
        guard let set = skyLightFunction("SLSSetAppearanceThemeSwitchesAutomatically", as: Setter.self)
        else { return false }
        set(enabled)
        return true
    }

    private static func skyLightFunction<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, name)
        else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
