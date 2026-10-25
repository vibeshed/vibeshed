import Foundation

/// The install actions' work, and the cask uninstall's. Installing something a Vibeshed
/// module works with (Spotify, iTerm, `gh`, …) also turns that module on in config.yaml.
extension HomebrewModule {
    func install(formula name: String, brewPath: String) async throws -> ActionResult {
        let before = SoftwareIntegration.detectedModuleIDs()
        let output = try await HomebrewManager.installFormula(name, brewPath: brewPath)
        invalidatePackageCache()
        let enabled = await enableModulesForInstall(since: before)
        let lines = [enabled, HomebrewManager.installSummary(output)].compactMap(\.self)
        return .showResult(title: "Installed \(name)", body: lines.joined(separator: "\n"))
    }

    func install(cask name: String, brewPath: String) async throws -> ActionResult {
        let before = SoftwareIntegration.detectedModuleIDs()
        let summary = try await HomebrewManager.installSummary(
            HomebrewManager.installCask(name, brewPath: brewPath)
        )
        invalidatePackageCache()
        // The install already succeeded; a failed lookup or launch shouldn't turn it into an error.
        let cask = try? await HomebrewManager.cask(name, brewPath: brewPath)
        await activateFonts(cask?.fontPaths ?? [])
        let appPaths = cask?.appPaths ?? []
        let enabled = await enableModulesForInstall(since: before, appPaths: appPaths)
        let launched = await HomebrewManager.launchFirstApp(at: appPaths).map { path in
            "Launched " + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        let lines = [launched, enabled, summary].compactMap(\.self)
        return .showResult(title: "Installed \(name)", body: lines.joined(separator: "\n"))
    }

    func uninstall(cask name: String, brewPath: String) async throws -> ActionResult {
        // Fonts `activateFonts` registered would stay listed after their files are gone,
        // and CoreText can only unregister them while the files are there.
        let cask = try? await HomebrewManager.cask(name, brewPath: brewPath)
        let unregistered = await FontActivation.deactivate(cask?.fontPaths ?? [])
        if !unregistered.isEmpty {
            log.info("Unregistered \(unregistered.count) font files before uninstalling \(name, privacy: .public)")
        }
        let output: String
        do {
            output = try await HomebrewManager.uninstallCask(name, brewPath: brewPath)
        } catch {
            await activateFonts(unregistered)
            throw error
        }
        invalidatePackageCache()
        return .showResult(title: "Uninstalled \(name)", body: output)
    }

    /// Makes a cask's fonts usable right away, in Switch Font and in the apps it sets them
    /// in. fontd misses them when the cask created ~/Library/Fonts, as on a new account.
    private func activateFonts(_ paths: [String]) async {
        let outcome = await FontActivation.activate(paths)
        if !outcome.registered.isEmpty {
            log.info("Registered \(outcome.registered.count) font files fontd hadn't picked up")
        }
        for (path, code) in outcome.failed.sorted(by: { $0.key < $1.key }) {
            log.warning("Couldn't register font \(path, privacy: .public): CoreText error \(code)")
        }
    }

    /// Turns on the modules for software that wasn't there `before` (module IDs) and is
    /// now. A cask's `appPaths` count even if LaunchServices hasn't picked them up yet.
    /// Returns a line for the result, or nil when no module was turned on.
    private func enableModulesForInstall(since before: Set<String>, appPaths: [String] = []) async -> String? {
        let bundleIDs = Set(appPaths.compactMap { Bundle(path: $0)?.bundleIdentifier })
        let added = SoftwareIntegration.added(since: before, in: SoftwareEnvironment.live.adding(apps: bundleIDs))
        guard !added.isEmpty else { return nil }
        let enabled = await enableModules(added)
        guard !enabled.isEmpty else { return nil }
        log.info("Turned on modules after an install: \(enabled.joined(separator: ", "), privacy: .public)")
        let modules = ListFormatter.localizedString(byJoining: enabled)
        return "Turned on the \(modules) \(enabled.count == 1 ? "module" : "modules") in config.yaml"
    }
}
