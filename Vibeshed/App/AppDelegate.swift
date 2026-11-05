import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let eventBus: EventBus
    let configManager: ConfigManager
    let permissionsManager: PermissionsManager
    let pickerState: PickerState
    let panelController: PanelController
    let moduleRegistry: ModuleRegistry
    let keyComboManager: KeyComboManager
    let uriManager: URIManager
    let usageTracker: UsageTracker
    let pickerCoordinator: PickerCoordinator
    let autostartManager: AutostartManager
    let aliasManager: AliasManager
    let layoutTransliterator: LayoutTransliterator
    let keystrokeVisualizer: KeystrokeVisualizer
    private(set) lazy var homebrewArrival = HomebrewArrival(configManager: configManager)
    private(set) lazy var permissionSetup = PermissionSetup(
        permissionsManager: permissionsManager,
        moduleRegistry: moduleRegistry,
        configManager: configManager
    )

    override init() {
        self.eventBus = EventBus()
        self.configManager = ConfigManager(eventBus: eventBus)
        self.permissionsManager = PermissionsManager(eventBus: eventBus)
        self.pickerState = PickerState()
        self.panelController = PanelController(pickerState: pickerState, configManager: configManager)
        self.moduleRegistry = ModuleRegistry(
            eventBus: eventBus,
            configManager: configManager,
            permissionsManager: permissionsManager
        )
        self.usageTracker = UsageTracker()
        self.autostartManager = AutostartManager()
        self.pickerCoordinator = PickerCoordinator(
            pickerState: pickerState,
            moduleRegistry: moduleRegistry,
            panelController: panelController,
            eventBus: eventBus
        )
        self.aliasManager = AliasManager(configManager: configManager, eventBus: eventBus)
        self.layoutTransliterator = LayoutTransliterator(configManager: configManager, eventBus: eventBus)
        pickerCoordinator.usageTracker = usageTracker
        pickerCoordinator.aliasManager = aliasManager
        pickerCoordinator.layoutTransliterator = layoutTransliterator
        moduleRegistry.aliasManager = aliasManager
        panelController.coordinator = pickerCoordinator

        // keyComboManager and uriManager need panelController, so we init them after
        let panel = panelController
        let picker = pickerState
        let coordinator = pickerCoordinator
        self.keyComboManager = KeyComboManager(
            eventBus: eventBus,
            configManager: configManager,
            moduleRegistry: moduleRegistry,
            permissionsManager: permissionsManager,
            togglePicker: { panel.toggle() },
            showParameterInput: { action in
                coordinator.showForParameterInput(action: action)
            }
        )
        self.keystrokeVisualizer = Self.makeKeystrokeVisualizer(
            keyComboManager: keyComboManager, moduleRegistry: moduleRegistry
        )
        self.uriManager = URIManager(
            eventBus: eventBus,
            configManager: configManager,
            moduleRegistry: moduleRegistry,
            showPicker: { query in
                // A query is a new search, not one for the list the picker was left on.
                panel.show(fresh: query != nil)
                if let query {
                    picker.query = query
                }
            },
            togglePicker: { panel.toggle() },
            showURLChooser: { _, actions in
                Self.showURLChooser(actions, panel: panel, coordinator: coordinator)
            }
        )
        super.init()
    }

    var isUITesting: Bool {
        CommandLine.arguments.contains("--ui-testing")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }

        Log.stderr("Vibeshed starting…")
        configManager.start()
        if configManager.wroteInitialConfig, !isUITesting {
            PermissionSetup.isPending = true
        }
        homebrewArrival.start()
        aliasManager.start()
        moduleRegistry.startListeningForConfigChanges()
        permissionsManager.checkAll()
        logPermissionStatus()
        permissionsManager.startPeriodicRecheck()
        panelController.startOverlay()
        layoutTransliterator.start()
        pickerCoordinator.start()
        keyComboManager.startListening()
        keyComboManager.applyBindings(
            configManager.config.keybindings,
            exclusions: configManager.config.keybindingExclusions
        )
        uriManager.start()

        if isUITesting {
            setupUITesting()
        } else {
            registerModules()
        }

        Log.app.info("Vibeshed launched")
        Log.stderr("Vibeshed launched (use ⌘Q in menu bar to quit)")
    }

    /// Returns `true` if this is the only running instance, `false` if another instance was found and activated.
    private func ensureSingleInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ivandmitriev.Vibeshed"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        guard let existing = others.first else { return true }

        let pid = existing.processIdentifier
        Log.app.warning(
            "Another Vibeshed instance already running (PID \(pid, privacy: .public)). Terminating."
        )
        existing.activate()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return false
    }

    private func registerModules() {
        Task { @MainActor in
            let modules: [any Module] = [
                WindowModule(),
                TilingModule(),
                ApplicationModule(),
                MenuModule(),
                SystemModule(),
                ProcessesModule(),
                PerformanceModule(),
                SettingsModule(),
                ThemeModule(),
                WallpaperModule(),
                buildSelfModule(),
                AudioModule(),
                ClipboardModule(),
                BrowserModule(),
                SpotifyModule(),
                GitHubModule(),
                RecentProjectsModule<VSCodeProvider>(),
                RecentProjectsModule<JetBrainsProvider>(),
                RecentProjectsModule<ZedProvider>(),
                ITermModule(),
                GhosttyModule(),
                TerminalModule(),
                AISessionsModule<AnthropicProvider>(),
                AISessionsModule<OpenAIProvider>(),
                AISessionsModule<OpenCodeProvider>(),
                TelegramModule(),
                ZoomModule(),
                CalendarModule(),
                MeetingPrepModule(),
                BookmarkModule(),
                SafariModule(),
                RecentFilesModule(),
                NotesModule(),
                TimerModule(),
                MathModule(),
                buildHomebrewModule(),
                WebSearchModule(),
                EmojiModule(),
            ]
            // Register concurrently: each module's initialize does independent I/O
            // (SQLite reads, disk scans), so time-to-ready is the slowest module
            // rather than the sum of all of them.
            await withTaskGroup(of: Void.self) { group in
                for module in modules {
                    group.addTask {
                        await self.registerModule(module)
                    }
                }
            }
            // Which permissions to ask for depends on the registered modules. On first
            // launch the setup window asks for all of them, one prompt at a time; later
            // launches ask only for what Vibeshed asks for at every launch.
            if PermissionSetup.isPending {
                await permissionSetup.show(welcome: true)
            } else {
                await permissionSetup.requestAtLaunch()
            }
        }
    }

    private func registerModule(_ module: any Module) async {
        let id = await module.id
        do {
            try await moduleRegistry.register(module)
        } catch {
            Log.stderr("  ✗ module: \(id) — \(error.localizedDescription)")
            Log.app.error(
                "Failed to register \(id, privacy: .public) module: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        // register() returns without throwing when blocked by permissions — check if actually loaded
        if let permissionError = moduleRegistry.permissionErrors[id] {
            let missing = permissionError.grantInstructions.joined(separator: ", ")
            Log.stderr("  ⚠ module: \(id) — waiting for permissions (\(missing))")
        } else if let configError = moduleRegistry.configErrors[id] {
            Log.stderr("  ✗ module: \(id) — config error: \(configError)")
        } else {
            Log.stderr("  ✓ module: \(id)")
        }
    }

    /// Installing an app a module works with turns that module on in config.yaml.
    private func buildHomebrewModule() -> HomebrewModule {
        let cfgManager = configManager
        return HomebrewModule(enableModules: { integrations in
            await cfgManager.enableModules(integrations.map { DefaultConfig.Entry($0) })
        })
    }

    private func buildSelfModule() -> SelfModule {
        let cfgManager = configManager
        let registry = moduleRegistry
        let visualizer = keystrokeVisualizer

        return SelfModule(
            configFileURL: cfgManager.configFileURL,
            configDirURL: cfgManager.configDirectoryURL,
            reloadConfig: { @MainActor in
                cfgManager.reload()
            },
            getModuleStatus: { @MainActor in
                var entries: [ModuleStatusInfo.Entry] = []
                for id in registry.moduleIDs {
                    entries.append(.init(id: id, status: .loaded, message: nil))
                }
                for (id, msg) in registry.configErrors {
                    entries.append(
                        .init(
                            id: id, status: .configError, message: msg
                        )
                    )
                }
                for (id, err) in registry.permissionErrors {
                    entries.append(
                        .init(
                            id: id,
                            status: .permissionError,
                            message: err.localizedDescription
                        )
                    )
                }
                return ModuleStatusInfo(
                    entries: entries.sorted { $0.id < $1.id }
                )
            },
            toggleKeystrokeVisualizer: { @MainActor in
                visualizer.toggle()
            }
        )
    }

    private func logPermissionStatus() {
        for permission in Permission.allCases {
            let granted = permissionsManager.isGranted(permission)
            let mark = granted ? "✓" : "✗"
            Log.stderr("  \(mark) permission: \(permission.displayName)")
        }
    }

    private func setupUITesting() {
        Task { @MainActor in
            let mockModule = MockModule()
            try await moduleRegistry.register(mockModule)
            panelController.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        uriManager.handleURLs(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        panelController.show()
        return false
    }
}

// MARK: - Keystroke Visualizer

extension AppDelegate {
    private static func makeKeystrokeVisualizer(
        keyComboManager: KeyComboManager,
        moduleRegistry: ModuleRegistry
    ) -> KeystrokeVisualizer {
        KeystrokeVisualizer(keyComboManager: keyComboManager) { actionID in
            // Built-in action with no module behind it (see KeyComboManager).
            if actionID.rawValue == "app/togglePicker" {
                return "Toggle Picker"
            }
            return await moduleRegistry.findAction(id: actionID)?.title
        }
    }
}

// MARK: - URL Chooser

extension AppDelegate {
    /// Shows the picker listing browser choices for a URL that no routing rule claimed.
    /// Escape closes it, opening nothing.
    private static func showURLChooser(
        _ actions: [any Action],
        panel: PanelController,
        coordinator: PickerCoordinator
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let items = actions.map { action in
            ActionItem(
                id: action.id,
                title: action.title,
                subtitle: action.subtitle,
                iconSystemName: action.iconName,
                appIconPath: action.appIconPath,
                score: action.relevanceScore,
                moduleID: "url",
                hasParameters: false,
                keywords: action.keywords
            )
        }
        var cache: [ActionID: any Action] = [:]
        for action in actions {
            cache[action.id] = action
        }
        coordinator.presentRootList(items, cache: cache)
        panel.setStaysOpenOnResignKey(true)
    }
}
