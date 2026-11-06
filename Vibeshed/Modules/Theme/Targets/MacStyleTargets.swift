import Foundation

/// A macOS setting a theme may have an opinion on (see `MacStyle`). Applying a theme with
/// one sets it and remembers what you had; a theme without one gives yours back, unless
/// you changed the setting yourself since a theme set it, in which case that stays.
/// Values travel as strings, the form they're remembered in.
struct ThemedSystemSetting: Sendable {
    /// Names the Vibeshed defaults keys.
    let name: String
    /// The current value; nil where this macOS doesn't have the setting.
    let read: @MainActor @Sendable () -> String?
    let write: @MainActor @Sendable (String) -> Bool
    /// Why `read` may come back empty, for the outcome.
    let unavailable: String
    /// Tests keep their state out of the app's defaults.
    var suiteName: String?

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private var yoursKey: String { "theme.macos.\(name).yours" }
    private var appliedKey: String { "theme.macos.\(name).applied" }

    @MainActor
    func apply(_ wanted: String?) -> ThemeTargetOutcome {
        let defaults = defaults
        guard let current = read() else { return .skipped(unavailable) }
        let applied = defaults.string(forKey: appliedKey)
        guard let wanted else {
            guard let yours = defaults.string(forKey: yoursKey) else { return .skipped("the theme leaves it as is") }
            defaults.removeObject(forKey: yoursKey)
            defaults.removeObject(forKey: appliedKey)
            guard current == applied, current != yours else { return .applied() }
            return write(yours) ? .applied() : .failed("couldn't put your own setting back")
        }
        // The first change, or a setting you picked since the last one: that's what to give back.
        if defaults.string(forKey: yoursKey) == nil || current != applied {
            defaults.set(current, forKey: yoursKey)
        }
        defaults.set(wanted, forKey: appliedKey)
        guard current != wanted else { return .applied() }
        return write(wanted) ? .applied() : .failed("macOS didn't take the change")
    }

    /// Captures the setting and what's remembered about it, to revert a preview.
    @MainActor
    func snapshot() -> ThemeRestore? {
        guard let current = read() else { return nil }
        let defaults = defaults
        let yours = defaults.string(forKey: yoursKey)
        let applied = defaults.string(forKey: appliedKey)
        return { [self] in await restore(current, yours: yours, applied: applied) }
    }

    @MainActor
    private func restore(_ value: String, yours: String?, applied: String?) {
        let defaults = defaults
        defaults.set(yours, forKey: yoursKey)
        defaults.set(applied, forKey: appliedKey)
        if read() != value { _ = write(value) }
    }
}

// MARK: - Targets

/// Liquid Glass (System Settings › Appearance, macOS 27): how tinted translucent surfaces are.
struct GlassTarget: ThemeTarget {
    let id = ThemeTargetID.glass
    let displayName = "Liquid Glass"
    var supportsPreview: Bool { true }

    static let setting = ThemedSystemSetting(
        name: "glass",
        read: { LiquidGlass.current()?.stored },
        write: { LiquidGlass.Setting(stored: $0).map(LiquidGlass.set) ?? false },
        unavailable: "needs macOS 27"
    )

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        let wanted = request.theme.macStyle.glass.map { LiquidGlass.Setting(tint: $0).stored }
        let outcome = await Self.setting.apply(wanted)
        if wanted != nil, outcome == .applied(), await LiquidGlass.isOverridden {
            return .applied(note: "Reduce Transparency is on, which hides the glass")
        }
        return outcome
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        await Self.setting.snapshot()
    }
}

/// Icon & widget style (System Settings › Appearance, macOS 26+). Tinted styles take the
/// color the `folders` target sets.
struct IconStyleTarget: ThemeTarget {
    let id = ThemeTargetID.icons
    let displayName = "Icon style"
    var supportsPreview: Bool { true }

    static let setting = ThemedSystemSetting(
        name: "icons",
        read: { IconAppearance.style()?.systemName },
        write: { IconStyle(systemName: $0).map(IconAppearance.setStyle) ?? false },
        unavailable: "needs macOS 26"
    )

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        await Self.setting.apply(request.theme.macStyle.iconStyle?.systemName)
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        await Self.setting.snapshot()
    }
}

/// "Show menu bar background" (System Settings › Menu Bar, macOS 26+).
struct MenuBarTarget: ThemeTarget {
    let id = ThemeTargetID.menubar
    let displayName = "Menu bar"
    var supportsPreview: Bool { true }

    static let setting = ThemedSystemSetting(
        name: "menubar",
        read: { MenuBarAppearance.background?.rawValue },
        write: { MenuBarBackground(rawValue: $0).map(MenuBarAppearance.setBackground) ?? false },
        unavailable: "needs macOS 26"
    )

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        await Self.setting.apply(request.theme.macStyle.menuBarBackground?.rawValue)
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        await Self.setting.snapshot()
    }
}
