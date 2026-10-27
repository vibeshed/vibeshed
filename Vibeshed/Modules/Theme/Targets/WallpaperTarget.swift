import AppKit
import Foundation

/// Sets every screen's wallpaper to the theme's image, or — for themes without one — one
/// generated from the palette in the chosen `WallpaperStyle`. Uses `NSWorkspace` directly (no Automation
/// permission); like System Settings, it changes the wallpaper of the current Space.
struct WallpaperTarget: ThemeTarget {
    let id = ThemeTargetID.wallpaper
    let displayName = "Wallpaper"
    var supportsPreview: Bool { true }

    /// Renders (into the cache `apply` reads) ahead of the other targets.
    func prepare(_ request: ThemeApplyRequest) async {
        guard request.theme.wallpaper == nil, request.config.generateWallpapers else { return }
        _ = await WallpaperRenderer.render(request.theme, choice: request.wallpaper)
    }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        // A preview superseded mid-run: the next one sets its own wallpaper.
        if request.isPreview, Task.isCancelled { return .skipped("superseded") }
        let url: URL
        if let path = request.theme.wallpaper {
            url = URL(fileURLWithPath: path)
        } else if request.config.generateWallpapers {
            guard let generated = await WallpaperRenderer.render(request.theme, choice: request.wallpaper) else {
                return .failed("couldn't render a wallpaper")
            }
            url = generated
        } else {
            return .skipped("theme has no wallpaper")
        }
        let outcome = await Self.set(url)
        if !request.isPreview { await WallpaperRenderer.prune() }
        return outcome
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        let saved = await Self.currentWallpapers()
        return { await Self.restore(saved) }
    }

    private struct SavedWallpaper: Sendable {
        let screenNumber: Int
        let url: URL
    }

    @MainActor
    private static func set(_ url: URL) -> ThemeTargetOutcome {
        // Already on every screen (a theme generated from the current wallpaper): leave it
        // as System Settings set it up rather than re-setting it with our options.
        let target = url.standardizedFileURL
        if NSScreen.screens.allSatisfy({ NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL == target }) {
            return .applied()
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            for screen in NSScreen.screens {
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

private extension NSScreen {
    var displayNumber: Int? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}
