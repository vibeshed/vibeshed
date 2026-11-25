import Foundation
import OSLog

actor HomebrewModule: ModuleConfigurable {
    let id = "homebrew"
    let displayName = "Homebrew"
    let iconName = "cup.and.saucer"
    var isEnabled = true

    typealias Config = HomebrewConfig
    static var defaultConfig: Config? {
        .init()
    }

    private var config: HomebrewConfig = .init()
    let log = Log.module("homebrew")
    /// Recent `brew info` results for the pickers (see HomebrewModule+Options.swift).
    var packageCache = HomebrewPackageCache()
    /// Turns on the Vibeshed modules for software an install added and returns their IDs;
    /// the app hands in `ConfigManager.enableModules` (see HomebrewModule+Install.swift).
    let enableModules: @Sendable ([DetectedIntegration]) async -> [String]

    init(enableModules: @escaping @Sendable ([DetectedIntegration]) async -> [String] = { _ in [] }) {
        self.enableModules = enableModules
    }

    func initialize(context: ModuleContext) async throws {
        log.info("Homebrew module initialized")
    }

    func configDidUpdate(_ config: HomebrewConfig) async {
        self.config = config
        packageCache = HomebrewPackageCache()
        log.debug("Config updated")
    }

    static func validate(_ config: HomebrewConfig) -> ConfigValidationResult {
        if config.brewPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid(["brewPath cannot be empty"])
        }
        return .valid
    }

    func provideActions(query: String, scoring: ScoringContext) async -> [any Action] {
        buildActions(config: config)
    }

    func provideParameterOptions(
        for parameterID: String,
        in actionID: ActionID,
        query: String
    ) async -> [ParameterOption] {
        let brewPath = config.brewPath
        switch actionID.actionName {
        case "installFormula":
            return await searchOptions(query: query, isCask: false, brewPath: brewPath)
        case "installCask":
            return await searchOptions(query: query, isCask: true, brewPath: brewPath)
        case "uninstallFormula":
            return await installedOptions(isCask: false, brewPath: brewPath)
        case "uninstallCask":
            return await installedOptions(isCask: true, brewPath: brewPath)
        default:
            return []
        }
    }

    // MARK: - Build Actions

    private func buildActions(config: HomebrewConfig) -> [HomebrewAction] {
        let enabled = config.enabledActions
        var actions: [HomebrewAction] = []

        actions.append(contentsOf: buildInstallActions(brewPath: config.brewPath))
        actions.append(contentsOf: buildUninstallActions(brewPath: config.brewPath))
        actions.append(contentsOf: buildMaintenanceActions(brewPath: config.brewPath))

        if let enabled {
            return actions.filter { enabled.contains($0.id.actionName) }
        }
        return actions
    }

    private func buildInstallActions(brewPath: String) -> [HomebrewAction] {
        [
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "installFormula"),
                title: "Install Formula",
                subtitle: "Install a Homebrew formula",
                iconName: "plus.circle",
                relevanceScore: 0.85,
                keywords: ["brew", "install", "formula", "package", "homebrew"],
                parameters: [
                    ActionParameter(
                        id: "package",
                        label: "Formula",
                        type: .dynamicSelection(hint: "formula"),
                        isRequired: true
                    ),
                ]
            ) { values in
                guard let name = values["package"], !name.isEmpty else {
                    return .showResult(title: "Error", body: "No formula specified")
                }
                return try await self.install(formula: name, brewPath: brewPath)
            },
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "installCask"),
                title: "Install Cask",
                subtitle: "Install a Homebrew cask (GUI app)",
                iconName: "plus.app",
                relevanceScore: 0.85,
                keywords: ["brew", "install", "cask", "app", "application", "homebrew"],
                parameters: [
                    ActionParameter(
                        id: "package",
                        label: "Cask",
                        type: .dynamicSelection(hint: "cask"),
                        isRequired: true
                    ),
                ]
            ) { values in
                guard let name = values["package"], !name.isEmpty else {
                    return .showResult(title: "Error", body: "No cask specified")
                }
                return try await self.install(cask: name, brewPath: brewPath)
            },
        ]
    }

    private func buildUninstallActions(brewPath: String) -> [HomebrewAction] {
        [
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "uninstallFormula"),
                title: "Uninstall Formula",
                subtitle: "Remove an installed Homebrew formula",
                iconName: "minus.circle",
                relevanceScore: 0.75,
                keywords: ["brew", "uninstall", "remove", "formula", "package", "homebrew"],
                parameters: [
                    ActionParameter(
                        id: "package",
                        label: "Formula",
                        type: .dynamicSelection(hint: "installed formula"),
                        isRequired: true
                    ),
                ]
            ) { values in
                guard let name = values["package"], !name.isEmpty else {
                    return .showResult(title: "Error", body: "No formula specified")
                }
                let output = try await HomebrewManager.uninstallFormula(name, brewPath: brewPath)
                await self.invalidatePackageCache()
                return .showResult(title: "Uninstalled \(name)", body: output)
            },
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "uninstallCask"),
                title: "Uninstall Cask",
                subtitle: "Remove an installed Homebrew cask",
                iconName: "minus.circle.fill",
                relevanceScore: 0.75,
                keywords: ["brew", "uninstall", "remove", "cask", "app", "application", "homebrew"],
                parameters: [
                    ActionParameter(
                        id: "package",
                        label: "Cask",
                        type: .dynamicSelection(hint: "installed cask"),
                        isRequired: true
                    ),
                ]
            ) { values in
                guard let name = values["package"], !name.isEmpty else {
                    return .showResult(title: "Error", body: "No cask specified")
                }
                return try await self.uninstall(cask: name, brewPath: brewPath)
            },
        ]
    }

    private func buildMaintenanceActions(brewPath: String) -> [HomebrewAction] {
        [
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "update"),
                title: "Brew Update",
                subtitle: "Update Homebrew and all tap repositories",
                iconName: "arrow.triangle.2.circlepath",
                relevanceScore: 0.7,
                keywords: ["brew", "update", "fetch", "homebrew"]
            ) { _ in
                let output = try await HomebrewManager.update(brewPath: brewPath)
                await self.invalidatePackageCache()
                return .showResult(title: "Homebrew Updated", body: output.isEmpty ? "Already up-to-date" : output)
            },
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "upgrade"),
                title: "Brew Upgrade",
                subtitle: "Upgrade all outdated packages",
                iconName: "arrow.up.circle",
                relevanceScore: 0.7,
                keywords: ["brew", "upgrade", "outdated", "homebrew"]
            ) { _ in
                let output = try await HomebrewManager.upgrade(brewPath: brewPath)
                await self.invalidatePackageCache()
                return .showResult(title: "Packages Upgraded", body: output.isEmpty ? "Everything up-to-date" : output)
            },
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "outdated"),
                title: "Brew Outdated",
                subtitle: "List packages with available updates",
                iconName: "clock.arrow.circlepath",
                relevanceScore: 0.65,
                keywords: ["brew", "outdated", "updates", "stale", "homebrew"]
            ) { _ in
                let packages = try await HomebrewManager.outdated(brewPath: brewPath)
                if packages.isEmpty {
                    return .showResult(title: "All Up-to-Date", body: "No outdated packages")
                }
                let list = packages.map { $0.description ?? $0.name }.joined(separator: "\n")
                return .showResult(title: "\(packages.count) Outdated", body: list)
            },
            HomebrewAction(
                id: ActionID(module: "homebrew", name: "cleanup"),
                title: "Brew Cleanup",
                subtitle: "Remove stale lock files and outdated downloads",
                iconName: "trash.circle",
                relevanceScore: 0.6,
                keywords: ["brew", "cleanup", "clean", "cache", "homebrew"]
            ) { _ in
                let output = try await HomebrewManager.cleanup(brewPath: brewPath)
                return .showResult(title: "Cleanup Complete", body: output.isEmpty ? "Nothing to clean" : output)
            },
        ]
    }
}
