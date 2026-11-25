import AppKit
import Foundation

/// Sets every screen's wallpaper to the theme's image, or — for themes without one — one
/// generated from the palette in the chosen `WallpaperStyle`, drawn for each display's own
/// size (and laid across all of them in the styles that span). Uses `NSWorkspace` directly
/// (no Automation permission); like System Settings, it changes the wallpaper of the current Space.
struct WallpaperTarget: ThemeTarget {
    let id = ThemeTargetID.wallpaper
    let displayName = "Wallpaper"
    var supportsPreview: Bool { true }

    /// Renders (into the cache `apply` reads) ahead of the other targets.
    func prepare(_ request: ThemeApplyRequest) async {
        guard request.theme.wallpaper == nil, request.config.generateWallpapers else { return }
        _ = await Self.render(request)
    }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        let outcome: ThemeTargetOutcome
        if let path = request.theme.wallpaper {
            outcome = await Self.set { _ in URL(fileURLWithPath: path) }
        } else if request.config.generateWallpapers {
            let generated = await Self.render(request)
            guard !generated.isEmpty else { return .failed("couldn't render a wallpaper") }
            outcome = await Self.set { generated[$0] }
        } else {
            return .skipped("theme has no wallpaper")
        }
        if !request.isPreview { await WallpaperRenderer.prune() }
        return outcome
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        let saved = await Self.currentWallpapers()
        return { await Self.restore(saved) }
    }

    private static func render(_ request: ThemeApplyRequest) async -> [Int: URL] {
        await WallpaperRenderer.render(
            request.theme, choice: request.wallpaper, spanning: request.config.wallpaperSpan
        )
    }

    private struct SavedWallpaper: Sendable {
        let screenNumber: Int
        let url: URL
    }

    /// Sets each screen's file, by display number; a screen without one is left alone.
    @MainActor
    private static func set(_ file: (Int) -> URL?) -> ThemeTargetOutcome {
        let screens = NSScreen.screens.compactMap { screen in
            screen.displayNumber.flatMap(file).map { (screen, $0.standardizedFileURL) }
        }
        // Already on screen (a theme generated from the current wallpaper): leave it as
        // System Settings set it up rather than re-setting it with our options.
        let changed = screens.filter { screen, url in
            NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != url
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            for (screen, url) in changed {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            }
            return .applied()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
    private static func currentWallpapers() -> [SavedWallpaper] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.displayNumber,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen)
            else { return nil }
            return SavedWallpaper(screenNumber: number, url: url)
        }
    }

    @MainActor
    private static func restore(_ saved: [SavedWallpaper]) {
        for screen in NSScreen.screens {
            guard let entry = saved.first(where: { $0.screenNumber == screen.displayNumber }) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(entry.url, for: screen, options: [:])
        }
    }
}
