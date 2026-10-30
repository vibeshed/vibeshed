import Foundation
import OSLog

actor SystemModule: ModuleConfigurable {
    let id = "system"
    let displayName = "System"
    let iconName = "gearshape"
    var isEnabled = true

    typealias Config = SystemConfig
    static var defaultConfig: Config? {
        .init()
    }

    private var config: SystemConfig = .init()

    /// Restart, shut down, log out, appearance, Dock and menu bar go through System
    /// Events, emptying the Trash through Finder: whichever of them are enabled.
    var automationTargets: [String] {
        let systemEventsActions: Set = [
            "restart", "shutdown", "logout", "toggleAppearance", "autoAppearance", "toggleDock", "toggleMenuBar",
        ]
        let enabled = config.enabledActions
        let usesSystemEvents = enabled.map { !$0.isDisjoint(with: systemEventsActions) } ?? true
        let usesFinder = enabled?.contains("emptyTrash") ?? true
        return (usesSystemEvents ? [AutomationConsent.systemEvents] : [])
            + (usesFinder ? [AutomationConsent.finder] : [])
    }
    private let log = Log.module("system")

    func initialize(context: ModuleContext) async throws {
        log.info("System module initialized")
    }

    func configDidUpdate(_ config: SystemConfig) async {
        self.config = config
        log.debug("Config updated")
    }

    static func validate(_ config: SystemConfig) -> ConfigValidationResult {
        let path = config.screenshotPath
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid(["screenshotPath cannot be empty"])
        }
        return .valid
    }

    func provideActions(query: String, scoring: ScoringContext) async -> [any Action] {
        buildActions(config: config)
    }

    // MARK: - Build Actions

    private func buildActions(config: SystemConfig) -> [SystemAction] {
        let enabled = config.enabledActions
        var actions: [SystemAction] = []

        actions.append(contentsOf: buildPowerActions())
        actions.append(contentsOf: buildDesktopActions())
        actions.append(contentsOf: buildAppearanceActions())
        actions.append(contentsOf: buildDockAndMenuBarActions())
        actions.append(contentsOf: buildTrashActions())
        actions.append(contentsOf: buildScreenshotActions(path: config.screenshotPath))
        actions.append(contentsOf: buildMaintenanceActions())

        if let enabled {
            return actions.filter { enabled.contains(actionName($0.id)) }
        }
        return actions
    }

    private func actionName(_ id: ActionID) -> String {
        id.actionName
    }

    private func buildPowerActions() -> [SystemAction] {
        [
            SystemAction(
                id: ActionID(module: "system", name: "lock"),
                title: "Lock Screen",
                subtitle: "Lock the screen",
                iconName: "lock",
                relevanceScore: 0.8,
                keywords: ["lock", "screen", "sleep", "display", "system"]
            ) { _ in
                SystemManager.lockScreen()
                return .dismiss
            },
            SystemAction(
                id: ActionID(module: "system", name: "sleep"),
                title: "Sleep",
                subtitle: "Put the Mac to sleep",
                iconName: "moon",
                relevanceScore: 0.7,
                keywords: ["sleep", "suspend", "system"]
            ) { _ in
                SystemManager.sleep()
                return .dismiss
            },
            SystemAction(
                id: ActionID(module: "system", name: "restart"),
                title: "Restart",
                subtitle: "Restart the Mac",
                iconName: "arrow.clockwise",
                relevanceScore: 0.6,
                keywords: ["restart", "reboot", "system"]
            ) { _ in
                try SystemManager.restart()
                return .dismiss
            },
            SystemAction(
                id: ActionID(module: "system", name: "shutdown"),
                title: "Shut Down",
                subtitle: "Shut down the Mac",
                iconName: "power",
                relevanceScore: 0.5,
                keywords: ["shutdown", "shut down", "power off", "system"]
            ) { _ in
                try SystemManager.shutdown()
                return .dismiss
            },
            SystemAction(
                id: ActionID(module: "system", name: "logout"),
                title: "Log Out",
                subtitle: "Log out of the current user session",
                iconName: "rectangle.portrait.and.arrow.forward",
                relevanceScore: 0.5,
                keywords: ["logout", "log out", "sign out", "session", "system"]
            ) { _ in
                try SystemManager.logout()
                return .dismiss
            },
        ]
    }

    private func buildDesktopActions() -> [SystemAction] {
        [
            SystemAction(
                id: ActionID(module: "system", name: "missionControl"),
                title: "Mission Control",
                subtitle: "Show all windows and desktops",
                iconName: "rectangle.3.group",
                relevanceScore: 0.8,
                keywords: ["mission", "control", "expose", "windows", "desktops", "overview", "system"]
            ) { _ in
                SystemManager.missionControl()
                return .dismiss
            },
        ]
    }

    private func buildAppearanceActions() -> [SystemAction] {
        [
            SystemAction(
                id: ActionID(module: "system", name: "toggleAppearance"),
                title: "Toggle Appearance",
                subtitle: "Switch between light and dark mode",
                iconName: "circle.lefthalf.filled",
                relevanceScore: 0.85,
                keywords: ["dark", "light", "mode", "appearance", "theme", "toggle", "system"]
            ) { _ in
                try SystemManager.toggleAppearance()
                return .dismiss
            },
            SystemAction(
                id: ActionID(module: "system", name: "autoAppearance"),
                title: "Set Auto Appearance",
                subtitle: "Switch appearance automatically based on time of day",
                iconName: "circle.lefthalf.filled.inverse",
                relevanceScore: 0.8,
                keywords: ["auto", "automatic", "dark", "light", "mode", "appearance", "theme", "system"]
            ) { _ in
                let body = SystemManager.setAutoAppearance()
                    ? "Appearance will now follow the system schedule"
                    : "Couldn't turn on Auto, set it in System Settings › Appearance"
                return .showResult(title: "Auto Appearance", body: body)
            },
        ]
    }

    private func buildDockAndMenuBarActions() -> [SystemAction] {
        [
            SystemAction(
                id: ActionID(module: "system", name: "toggleDock"),
                title: "Toggle Dock",
                subtitle: "Turn Dock auto-hide on or off",
                iconName: "dock.rectangle",
                relevanceScore: 0.8,
                keywords: ["dock", "hide", "show", "autohide", "auto-hide", "toggle", "system"]
            ) { _ in
                try SystemManager.toggleDockAutohide()
                return .dismiss
            },
            SystemAction(
                id: ActionID(module: "system", name: "toggleMenuBar"),
                title: "Toggle Menu Bar",
                subtitle: "Turn menu bar auto-hide on or off",
                iconName: "menubar.rectangle",
                relevanceScore: 0.8,
                keywords: ["menu", "menubar", "menu bar", "hide", "show", "autohide", "auto-hide", "toggle", "system"]
            ) { _ in
                try SystemManager.toggleMenuBarAutohide()
                return .dismiss
            },
        ]
    }

    private func buildTrashActions() -> [SystemAction] {
        [
            SystemAction(
                id: ActionID(module: "system", name: "emptyTrash"),
                title: "Empty Trash",
                subtitle: "Permanently delete all items in the Trash",
                iconName: "trash",
                relevanceScore: 0.6,
                keywords: ["empty", "trash", "delete", "clean", "system"]
            ) { _ in
                try SystemManager.emptyTrash()
                return .showResult(title: "Trash Emptied", body: "All items in the Trash have been deleted")
            },
        ]
    }

    private func buildScreenshotActions(path: String) -> [SystemAction] {
        let screenshotPath = path
        return [
            SystemAction(
                id: ActionID(module: "system", name: "screenshotFull"),
                title: "Screenshot (Full Screen)",
                subtitle: "Capture the entire screen to a file",
                iconName: "camera",
                relevanceScore: 0.75,
                keywords: ["screenshot", "capture", "screen", "full", "system"]
            ) { _ in
                try SystemManager.takeScreenshot(toClipboard: false, path: screenshotPath)
                return .showResult(title: "Screenshot Saved", body: "Saved to \(screenshotPath)")
            },
            SystemAction(
                id: ActionID(module: "system", name: "screenshotClipboard"),
                title: "Screenshot (to Clipboard)",
                subtitle: "Capture the entire screen to the clipboard",
                iconName: "camera.badge.ellipsis",
                relevanceScore: 0.75,
                keywords: ["screenshot", "capture", "screen", "clipboard", "copy", "system"]
            ) { _ in
                try SystemManager.takeScreenshot(toClipboard: true, path: screenshotPath)
                return .showResult(title: "Screenshot Copied", body: "Screenshot copied to clipboard")
            },
            SystemAction(
                id: ActionID(module: "system", name: "screenshotInteractive"),
                title: "Screenshot (Interactive)",
                subtitle: "Select an area to capture",
                iconName: "camera.viewfinder",
                relevanceScore: 0.8,
                keywords: ["screenshot", "capture", "screen", "select", "area", "interactive", "system"]
            ) { _ in
                try SystemManager.takeScreenshotInteractive(path: screenshotPath)
                return .dismiss
            },
        ]
    }

    private func buildMaintenanceActions() -> [SystemAction] {
        [
            SystemAction(
                id: ActionID(module: "system", name: "flushDNS"),
                title: "Flush DNS",
                subtitle: "Clear the DNS cache",
                iconName: "network",
                relevanceScore: 0.5,
                keywords: ["flush", "dns", "cache", "network", "system"]
            ) { _ in
                try SystemManager.flushDNS()
                return .showResult(title: "DNS Flushed", body: "DNS cache has been cleared")
            },
            SystemAction(
                id: ActionID(module: "system", name: "purgeMemory"),
                title: "Purge Memory",
                subtitle: "Free up inactive memory",
                iconName: "memorychip",
                relevanceScore: 0.5,
                keywords: ["purge", "memory", "ram", "free", "clean", "system"]
            ) { _ in
                try SystemManager.purgeMemory()
                return .showResult(title: "Memory Purged", body: "Inactive memory has been freed")
            },
        ]
    }
}
