import AppKit
import Foundation

struct ThemeApplyRequest: Sendable {
    let theme: ResolvedTheme
    let config: ThemeConfig
    /// True while live-previewing: targets skip slow or irreversible work.
    let isPreview: Bool
    /// How to generate a wallpaper when the theme doesn't ship an image.
    let wallpaper: WallpaperChoice

    var palette: ThemePalette { theme.palette }

    /// The theme's `apps:` override for this target, if any.
    func override(_ target: ThemeTargetID) -> String? {
        theme.appOverrides[target.rawValue]
    }
}

enum ThemeTargetOutcome: Sendable, Equatable {
    /// Applied; the note (if any) is worth telling the user, e.g. "restart to load".
    case applied(note: String? = nil)
    /// Nothing to do here — app not installed, not running, nothing configured.
    case skipped(String)
    case failed(String)
}

enum ThemeTargetError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(path): "couldn't parse \((path as NSString).lastPathComponent), left untouched"
        }
    }
}

/// Undoes what a preview changed. Captured before the first preview touches a target.
typealias ThemeRestore = @Sendable () async -> Void

/// Something a theme can be applied to: a macOS setting or an app.
protocol ThemeTarget: Sendable {
    var id: ThemeTargetID { get }
    var displayName: String { get }

    /// Cheap and reversible, so it's safe to run on every highlight change in
    /// `theme/switch`. Such targets must implement `snapshot`.
    var supportsPreview: Bool { get }

    /// The slow, invisible part of `apply` (rendering a wallpaper), run for every target
    /// before any `apply` so the targets change together. Must leave what `apply` needs
    /// cached; a cancelled preview may skip it.
    func prepare(_ request: ThemeApplyRequest) async

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome

    /// Captures the state `apply` is about to change, for reverting a cancelled preview.
    func snapshot(config: ThemeConfig) async -> ThemeRestore?
}

extension ThemeTarget {
    var supportsPreview: Bool { false }

    func prepare(_: ThemeApplyRequest) async {}

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? { nil }
}

// MARK: - File helpers

enum ThemeFiles {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Follows symlinks to the real file. Dotfile setups symlink configs into a repo; an
    /// atomic write to the link itself would replace it with a plain file and silently
    /// detach the config from the repo.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Writes atomically (to the symlink's target, if it is one), creating parent folders.
    /// Skips the write when the content is unchanged so file watchers in the target app
    /// don't fire for nothing.
    static func write(_ text: String, to path: String) throws {
        let path = resolved(path)
        if read(path) == text { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func writeJSON(_ object: Any, to path: String) throws {
        try write(JSONFormatting.pretty(object) + "\n", to: path)
    }

    /// Captures files' current contents (or absence) and returns a restore that puts
    /// them back exactly — used to revert previews of file-based targets.
    static func snapshot(_ paths: [String]) -> ThemeRestore {
        let saved = paths.map(resolved).map { ($0, FileManager.default.contents(atPath: $0)) }
        return {
            for (path, data) in saved {
                if let data {
                    if FileManager.default.contents(atPath: path) != data {
                        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                } else {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
    }
}

// MARK: - Running apps

enum ThemeApps {
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
