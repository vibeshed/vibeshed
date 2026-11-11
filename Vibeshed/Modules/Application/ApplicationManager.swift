import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

private let log = Log.module("application")

struct ApplicationManager: Sendable {
    // MARK: - List Installed Applications

    /// Where installed apps are looked up; earlier directories win when a bundle ID appears twice.
    static let applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
    ]

    /// User-facing apps in /System/Library/CoreServices, listed one by one because the rest of that
    /// tree is agents and helpers. Missing ones are skipped: Keychain Access moved here in macOS 15
    /// (from /System/Applications/Utilities, where Screen Sharing has been since macOS 14).
    static let coreServicesApps: [URL] = [
        "/System/Library/CoreServices/Finder.app",
        "/System/Library/CoreServices/Applications/Archive Utility.app",
        "/System/Library/CoreServices/Applications/Directory Utility.app",
        "/System/Library/CoreServices/Applications/Feedback Assistant.app",
        "/System/Library/CoreServices/Applications/Keychain Access.app",
        "/System/Library/CoreServices/Applications/Ticket Viewer.app",
        "/System/Library/CoreServices/Applications/Wireless Diagnostics.app",
    ].map { URL(fileURLWithPath: $0) }

    @MainActor
    func listInstalledApplications() -> [AppInfo] {
        var seen = Set<String>()
        var apps: [AppInfo] = []
        let runningApps = NSWorkspace.shared.runningApplications
        let runningByBundleID = Dictionary(
            runningApps.compactMap { app -> (String, NSRunningApplication)? in
                guard let bid = app.bundleIdentifier else { return nil }
                return (bid, app)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Single CGWindowList call for all window counts
        let windowCounts = WindowListHelper.countWindowsByPID()

        apps += installedApps(
            at: Self.installedAppBundleURLs(),
            runningByBundleID: runningByBundleID,
            windowCounts: windowCounts,
            seen: &seen
        )

        // Add running apps not found in standard directories
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  !seen.contains(bundleID),
                  app.activationPolicy == .regular,
                  let url = app.bundleURL
            else {
                continue
            }
            seen.insert(bundleID)
            let windowCount = windowCounts[app.processIdentifier] ?? 0
            apps.append(AppInfo(
                id: bundleID,
                name: app.localizedName ?? bundleID,
                bundleURL: url,
                isRunning: true,
                pid: app.processIdentifier,
                windowCount: windowCount
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Apps at `bundleURLs` whose ID isn't in `seen` yet; adds each one it returns to `seen`.
    @MainActor
    private func installedApps(
        at bundleURLs: [URL],
        runningByBundleID: [String: NSRunningApplication],
        windowCounts: [pid_t: Int],
        seen: inout Set<String>
    ) -> [AppInfo] {
        var apps: [AppInfo] = []
        for url in bundleURLs {
            guard let bundle = Bundle(url: url) else { continue }
            let appID = Self.appID(for: bundle)
            guard !seen.contains(appID) else { continue }
            seen.insert(appID)

            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            let running = runningByBundleID[appID]
            let windowCount = running
                .map { windowCounts[$0.processIdentifier] ?? 0 } ?? 0

            apps.append(AppInfo(
                id: appID,
                name: name,
                bundleURL: url,
                isRunning: running != nil,
                pid: running?.processIdentifier,
                windowCount: windowCount
            ))
        }
        return apps
    }

    /// Every app bundle to list, in lookup order: those found in `directories` by `appBundleURLs(in:)`,
    /// then the `extraApps` that exist.
    static func installedAppBundleURLs(
        directories: [URL] = applicationDirectories,
        extraApps: [URL] = coreServicesApps
    ) -> [URL] {
        directories.flatMap(appBundleURLs(in:))
            + extraApps.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `.app` bundles directly inside `dir` and inside its plain subfolders, one level down
    /// (`/System/Applications/Utilities`, `~/Applications/Chrome Apps.localized`, vendor folders).
    static func appBundleURLs(in dir: URL) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        var bundles: [URL] = []
        var folders: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if entry.pathExtension == "app" {
                bundles.append(entry)
            } else if let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isPackage != true
            {
                folders.append(entry)
            }
        }
        for folder in folders {
            let nested = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            bundles += nested.filter { $0.pathExtension == "app" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return bundles
    }

    /// The bundle ID, or the bundle's path for apps without one (e.g. Steam game shortcuts).
    static func appID(for bundle: Bundle) -> String {
        bundle.bundleIdentifier ?? bundle.bundleURL.path
    }

    // MARK: - List Running Applications

    @MainActor
    func listRunningApplications() -> [AppInfo] {
        let runningApps = NSWorkspace.shared.runningApplications
        let windowCounts = WindowListHelper.countWindowsByPID()
        var apps: [AppInfo] = []

        for app in runningApps {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let url = app.bundleURL
            else {
                continue
            }
            let windowCount = windowCounts[app.processIdentifier] ?? 0
            apps.append(AppInfo(
                id: bundleID,
                name: app.localizedName ?? bundleID,
                bundleURL: url,
                isRunning: true,
                pid: app.processIdentifier,
                windowCount: windowCount
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Launch Application

    /// Through `AppLauncher`, since any app may live in the menu bar or hide its Dock icon.
    @MainActor
    func launchApplication(_ app: AppInfo) async throws {
        log.debug("Launching application: \(app.name, privacy: .public) (\(app.id, privacy: .public))")
        try await AppLauncher.open(app.bundleURL)
        log.debug("Launched application: \(app.name, privacy: .public)")
    }

    // MARK: - Focus Application

    /// What `focusApplication` does with a running app.
    enum FocusStep: Equatable {
        /// The AX window query failed (no Accessibility permission, app not responding), so it
        /// may have windows: activate it, as a reopen could make it open another one.
        case activate
        /// No windows. activate() would only switch the menu bar. Opening a running app sends it
        /// a reopen event, as a Dock click does, so it shows a window (Finder opens a new one).
        case reopen
        /// Already frontmost: raise its next window.
        case cycleWindows
        /// Activate it, restoring a window first if all of them are minimized.
        case restoreAndActivate
    }

    /// `windowCount` is nil when the AX window query failed.
    static func focusStep(windowCount: Int?, isFrontmost: Bool) -> FocusStep {
        guard let windowCount else { return .activate }
        if windowCount == 0 { return .reopen }
        return isFrontmost ? .cycleWindows : .restoreAndActivate
    }

    @MainActor
    func focusApplication(_ app: AppInfo) async throws -> Bool {
        guard let running = findRunningApp(bundleID: app.id) else {
            log.warning("focusApplication: app not running \(app.id, privacy: .public)")
            return false
        }

        let axWindows = AXWindowHelper.windowsIfAvailable(for: running.processIdentifier)?
            .filter(AXWindowHelper.isWindow)
        let isFrontmost = running == NSWorkspace.shared.frontmostApplication
        switch Self.focusStep(windowCount: axWindows?.count, isFrontmost: isFrontmost) {
        case .activate:
            running.activate(options: [])
        case .reopen:
            log.debug("focusApplication: no windows, reopening \(app.id, privacy: .public)")
            try await launchApplication(app)
        case .cycleWindows:
            cycleWindows(axWindows ?? [], of: running)
        case .restoreAndActivate:
            restoreMinimizedWindows(axWindows ?? [])
            running.activate(options: [])
        }
        return true
    }

    // MARK: - Quit Application

    @MainActor
    func quitApplication(_ app: AppInfo) -> Bool {
        guard let running = findRunningApp(bundleID: app.id) else {
            log.warning("quitApplication: app not running \(app.id, privacy: .public)")
            return false
        }
        let result = running.terminate()
        if !result {
            log.warning("quitApplication: terminate returned false for \(app.id, privacy: .public)")
        }
        return result
    }

    // MARK: - Window Cycling

    @MainActor
    private func cycleWindows(_ axWindows: [AXUIElement], of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard axWindows.count > 1 else {
            if let only = axWindows.first, AXWindowHelper.isMinimized(only) {
                AXWindowHelper.deminiaturize(only)
            }
            app.activate(options: [])
            return
        }

        if let focused = AXWindowHelper.focusedWindow(for: pid),
           let focusedID = AXWindowHelper.windowID(for: focused)
        {
            for (index, axWindow) in axWindows.enumerated() {
                if let windowID = AXWindowHelper.windowID(for: axWindow), windowID == focusedID {
                    let nextIndex = (index + 1) % axWindows.count
                    let next = axWindows[nextIndex]
                    if AXWindowHelper.isMinimized(next) {
                        AXWindowHelper.deminiaturize(next)
                    }
                    AXUIElementPerformAction(next, kAXRaiseAction as CFString)
                    app.activate(options: [])
                    return
                }
            }
        }

        let first = axWindows[0]
        if AXWindowHelper.isMinimized(first) {
            AXWindowHelper.deminiaturize(first)
        }
        AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        app.activate(options: [])
    }

    private func restoreMinimizedWindows(_ axWindows: [AXUIElement]) {
        let allMinimized = !axWindows.isEmpty && axWindows.allSatisfy { AXWindowHelper.isMinimized($0) }
        if allMinimized, let first = axWindows.first {
            AXWindowHelper.deminiaturize(first)
        }
    }

    // MARK: - Private Helpers

    @MainActor
    private func findRunningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}
