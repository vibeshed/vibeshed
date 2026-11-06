import Foundation

/// System Settings › Menu Bar › "Show menu bar background" (macOS 26+), through the SkyLight
/// calls that pane makes: `SLSGetMenuBarUseBlurredAppearance()` and
/// `SLSSetMenuBarUseBlurredAppearance(_:_:)`, whose second argument the pane always passes
/// as true. A blurred appearance is the background; without it the menu bar is clear.
enum MenuBarAppearance {
    private typealias Getter = @convention(c) () -> Bool
    private typealias Setter = @convention(c) (Bool, Bool) -> Void

    /// Before macOS 26 the menu bar always had its translucent background.
    private static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0,
                                                                                 patchVersion: 0))
    }

    /// Nil where the setting doesn't exist.
    static var background: MenuBarBackground? {
        guard isSupported, let get = skyLightFunction("SLSGetMenuBarUseBlurredAppearance", as: Getter.self)
        else { return nil }
        return get() ? .show : .hide
    }

    /// Sets it, and confirms by reading it back.
    static func setBackground(_ background: MenuBarBackground) -> Bool {
        guard isSupported, let set = skyLightFunction("SLSSetMenuBarUseBlurredAppearance", as: Setter.self)
        else { return false }
        set(background == .show, true)
        return self.background == background
    }

    private static func skyLightFunction<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, name)
        else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
