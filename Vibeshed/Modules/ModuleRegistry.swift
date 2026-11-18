import CoreFoundation
import Foundation

@MainActor
@Observable
final class ModuleRegistry {
    private(set) var moduleIDs: [String] = []
    private(set) var configErrors: [String: String] = [:]
    private(set) var permissionErrors: [String: PermissionError] = [:]
    private var modules: [String: any Module] = [:]
    private var configDecoders: [String: ModuleConfigDecoder] = [:]
    private var pendingModules: [String: any Module] = [:]
    /// Modules held back by the config (no section yet, or one that doesn't validate),
    /// tried again whenever it changes.
    private var modulesAwaitingConfig: [String: any Module] = [:]
    var aliasManager: AliasManager?
    private let eventBus: EventBus
    private let configManager: ConfigManager
    private let permissionsManager: PermissionsManager

    init(eventBus: EventBus, configManager: ConfigManager, permissionsManager: PermissionsManager) {
        self.eventBus = eventBus
        self.configManager = configManager
        self.permissionsManager = permissionsManager
    }

    func startListeningForConfigChanges() {
        Task { [weak self] in
            guard let self else { return }
            let (_, stream) = await eventBus.subscribe()
            for await event in stream {
                switch event {
                case .configReloaded:
                    await self.propagateConfigChanges()
                    await self.retryModulesAwaitingConfig()
                case .permissionChanged:
                    await self.retryPendingModules()
                default:
                    break
                }
            }
        }
    }

    func register(_ module: any Module) async throws {
        let id = await module.id

        // 0. Skip modules whose config section is not present in YAML, until it is
        if module is any ModuleConfigurable,
           !configManager.config.moduleConfigs.keys.contains(id)
        {
            modulesAwaitingConfig[id] = module
            Log.modules.debug("Module '\(id, privacy: .public)' skipped: no config section")
            return
        }

        // 1. Check permissions before config and init
        let required = type(of: module).requiredPermissions
        if !required.isEmpty {
            let missing = permissionsManager.missingPermissions(from: required)
            if !missing.isEmpty {
                let error = PermissionError.denied(moduleID: id, permissions: missing)
                permissionErrors[id] = error
                pendingModules[id] = module
                modulesAwaitingConfig.removeValue(forKey: id)
                Log.modules.error(
                    "Module '\(id, privacy: .public)' not loaded: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        // 2. Validate config
        let decoder = buildConfigDecoder(for: module, id: id)

        if let decoder {
            let rawYAML = configManager.config.moduleConfigs[id]
            do {
                try decoder.validate(rawYAML)
            } catch {
                let message =
                    (error as? ModuleConfigError)?.errorDescription
                        ?? error.localizedDescription
                configErrors[id] = message
                modulesAwaitingConfig[id] = module
                pendingModules.removeValue(forKey: id)
                permissionErrors.removeValue(forKey: id)
                Log.modules.error(
                    "Module '\(id, privacy: .public)' not loaded: \(message, privacy: .public)"
                )
                return
            }
        }

        // 3. Initialize
        let context = ModuleContext(
            eventBus: eventBus,
            loggerFactory: { subcategory in
                Log.module("\(id).\(subcategory)")
            }
        )
        try await module.initialize(context: context)

        // 4. Apply config
        if let decoder {
            let rawYAML = configManager.config.moduleConfigs[id]
            try await decoder.apply(rawYAML)
        }

        markLoaded(module, id: id, decoder: decoder)
        Log.modules.info("Registered module: \(id, privacy: .public)")
        await eventBus.publish(.moduleRegistered(id))
    }

    /// Records a module as loaded, clearing whatever held it back before.
    private func markLoaded(_ module: any Module, id: String, decoder: ModuleConfigDecoder?) {
        modules[id] = module
        if let decoder { configDecoders[id] = decoder }
        moduleIDs.append(id)
        permissionErrors.removeValue(forKey: id)
        configErrors.removeValue(forKey: id)
        pendingModules.removeValue(forKey: id)
        modulesAwaitingConfig.removeValue(forKey: id)
    }

    func unregister(id: String) async {
        guard let module = modules.removeValue(forKey: id) else { return }
        moduleIDs.removeAll { $0 == id }
        configDecoders.removeValue(forKey: id)
        configErrors.removeValue(forKey: id)
        permissionErrors.removeValue(forKey: id)
        pendingModules.removeValue(forKey: id)
        await module.teardown()
        Log.modules.info("Unregistered module: \(id, privacy: .public)")
        await eventBus.publish(.moduleUnregistered(id))
    }

    private let moduleQueryTimeout: TimeInterval = 2.0

    /// Fetches the full catalog from query-independent modules (the vast majority).
    /// Called once per picker session and on module-change events — not per keystroke.
    func catalogActions(scoring: ScoringContext) async -> [any Action] {
        let signpostState = Log.signposter.beginInterval("ModuleCatalog")
        defer { Log.signposter.endInterval("ModuleCatalog", signpostState) }
        let catalogModules = modules.values.filter { !type(of: $0).isQueryDependent }
        return await fanOut(modules: Array(catalogModules), query: "", scoring: scoring)
    }

    /// Queries modules whose actions are computed from the query text (e.g. math).
    /// Called per keystroke — these modules must be fast.
    func searchActions(query: String, scoring: ScoringContext) async -> [any Action] {
        let searchModules = modules.values.filter { type(of: $0).isQueryDependent }
        guard !searchModules.isEmpty else { return [] }
        return await fanOut(modules: Array(searchModules), query: query, scoring: scoring)
    }

    private func fanOut(
        modules allModules: [any Module],
        query: String,
        scoring: ScoringContext
    ) async -> [any Action] {
        let timeout = moduleQueryTimeout

        return await withTaskGroup(of: [any Action].self) { group in
            for module in allModules {
                group.addTask {
                    guard await module.isEnabled else { return [] }
                    let moduleID = await module.id
                    let start = CFAbsoluteTimeGetCurrent()
                    do {
                        let actions = try await withThrowingTimeout(seconds: timeout) {
                            await module.provideActions(query: query, scoring: scoring)
                        }
                        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        let count = actions.count
                        Log.perf.debug(
                            "\(moduleID, privacy: .public): \(ms, format: .fixed(precision: 1))ms (\(count) actions)"
                        )
                        return actions
                    } catch {
                        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        Log.perf.warning(
                            "\(moduleID, privacy: .public): timed out after \(ms, format: .fixed(precision: 1))ms"
                        )
                        return []
                    }
                }
            }
            var results: [any Action] = []
            for await batch in group {
                results.append(contentsOf: batch)
            }
            return results
        }
    }

    /// Permissions the loaded modules and the ones waiting on permissions need to load.
    var requiredPermissions: Set<Permission> {
        Set(configuredModuleTypes.flatMap { $0.requiredPermissions })
    }

    /// Permissions those modules use but load without (see `Module.optionalPermissions`).
    var optionalPermissions: Set<Permission> {
        Set(configuredModuleTypes.flatMap { $0.optionalPermissions })
    }

    /// Apps those modules send Apple events to with their current settings (see
    /// `Module.automationTargets`).
    func automationTargets() async -> Set<String> {
        var targets = Set<String>()
        for module in Array(modules.values) + Array(pendingModules.values) {
            await targets.formUnion(module.automationTargets)
        }
        return targets
    }

    private var configuredModuleTypes: [any Module.Type] {
        (Array(modules.values) + Array(pendingModules.values)).map { type(of: $0) }
    }

    func module(id: String) -> (any Module)? {
        modules[id]
    }

    /// The loaded modules, in the order they loaded.
    var loadedModules: [any Module] {
        moduleIDs.compactMap { modules[$0] }
    }

    func findAction(id: ActionID) async -> (any Action)? {
        let moduleID = id.moduleID

        // Check if this is an alias action
        if moduleID == "alias", let aliasManager {
            let aliasName = String(id.rawValue.dropFirst("alias/".count))
            if let entry = aliasManager.findEntry(named: aliasName) {
                return aliasManager.buildAction(from: entry)
            }
            Log.modules.warning("Alias '\(aliasName, privacy: .public)' not found in config")
            return nil
        }

        // Check if module is loaded
        guard let module = modules[moduleID] else {
            // Check if it's pending (permissions not granted)
            if pendingModules[moduleID] != nil {
                let message = "Action '\(id)' not available: module '\(moduleID)' waiting for permissions"
                Log.modules.warning("\(message, privacy: .public)")
            } else {
                Log.modules.warning(
                    "Action '\(id, privacy: .public)' not found: module '\(moduleID, privacy: .public)' not registered"
                )
            }
            return nil
        }

        guard let action = await module.action(id: id) else {
            Log.modules.warning(
                "Action '\(id, privacy: .public)' not found in module '\(moduleID, privacy: .public)'"
            )
            return nil
        }

        return action
    }

    // MARK: - Private

    private func buildConfigDecoder(
        for module: any Module,
        id: String
    ) -> ModuleConfigDecoder? {
        func open(_ configurable: some ModuleConfigurable, id: String) -> ModuleConfigDecoder {
            ModuleConfigDecoder.make(for: configurable, moduleID: id)
        }
        guard let configurable = module as? any ModuleConfigurable else {
            return nil
        }
        return open(configurable, id: id)
    }

    private func propagateConfigChanges() async {
        for (id, decoder) in configDecoders {
            let rawYAML = configManager.config.moduleConfigs[id]
            do {
                try await decoder.apply(rawYAML)
                configErrors.removeValue(forKey: id)
            } catch {
                let message =
                    (error as? ModuleConfigError)?.errorDescription
                        ?? error.localizedDescription
                configErrors[id] = message
                Log.modules.error(
                    "Config change rejected for module '\(id, privacy: .public)': \(message, privacy: .public)"
                )
            }
        }
    }

    /// A section added while the app runs (by hand, or by a Homebrew install), or fixed
    /// so that it validates, loads its module without a restart. Removing a section
    /// still takes effect at the next launch.
    private func retryModulesAwaitingConfig() async {
        let configured = configManager.config.moduleConfigs.keys
        for (id, module) in modulesAwaitingConfig where configured.contains(id) {
            do {
                try await register(module)
                guard !modulesAwaitingConfig.keys.contains(id) else { continue }
                let state = moduleIDs.contains(id) ? "loaded" : "waiting for permissions"
                Log.modules.info("Module '\(id, privacy: .public)' \(state, privacy: .public) after a config change")
            } catch {
                let reason = error.localizedDescription
                Log.modules.error("Loading module '\(id, privacy: .public)' failed: \(reason, privacy: .public)")
            }
        }
    }

    private func retryPendingModules() async {
        let pending = pendingModules
        for (id, module) in pending {
            let required = type(of: module).requiredPermissions
            let missing = permissionsManager.missingPermissions(from: required)
            if missing.isEmpty {
                Log.modules.info("Retrying module '\(id, privacy: .public)' after permission grant")
                Log.stderr("  ↻ module: \(id) — retrying after permission grant")
                do {
                    try await register(module)
                    Log.stderr("  ✓ module: \(id) — loaded")
                } catch {
                    let reason = error.localizedDescription
                    Log.stderr("  ✗ module: \(id) — retry failed: \(reason)")
                    Log.modules.error("Retry failed for module '\(id, privacy: .public)': \(reason, privacy: .public)")
                }
            }
        }
    }
}

// MARK: - Timeout Utility

private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
