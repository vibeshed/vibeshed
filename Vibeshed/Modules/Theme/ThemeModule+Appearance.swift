import Foundation

/// Keeps a paired theme on the half that matches the system's light/dark mode.
extension ThemeModule {
    /// The theme a system switch last left, so the next one returns to it: from Latte,
    /// back to the Catppuccin dark variant that was in use rather than the first listed.
    private static let followedFromKey = "theme.followedFrom"

    func syncWithSystemAppearance() async {
        // Previews flip the system themselves, and their revert has to land before the
        // mode means anything.
        guard await applier.settled() else { return }
        // AppKit hears of a revert a moment after it finishes; hearing cancels this task.
        try? await Task.sleep(for: .seconds(0.5))
        guard !Task.isCancelled,
              let slug = await MainActor.run(body: { ActiveTheme.shared.committed?.slug }),
              let current = catalog.theme(slug: slug)
        else { return }

        let mode: ThemeMode = await SystemAppearance.isDark ? .dark : .light
        let followedFrom = UserDefaults.standard.string(forKey: Self.followedFromKey)
        guard let next = catalog.counterpart(of: current, for: mode, preferring: followedFrom) else { return }
        UserDefaults.standard.set(current.slug, forKey: Self.followedFromKey)
        let options = ThemeApplier.Options(wallpaper: wallpaperChoice(for: next), only: nil)
        await applier.applyUnlessPreviewing(next, config: config, options: options)
    }
}
