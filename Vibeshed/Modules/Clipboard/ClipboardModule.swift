import AppKit
import Foundation
import OSLog

actor ClipboardModule: ModuleConfigurable {
    let id = "clipboard"
    let displayName = "Clipboard"
    let iconName = "doc.on.clipboard"
    var isEnabled = true

    typealias Config = ClipboardConfig
    static var defaultConfig: Config? {
        .init()
    }

    private var config: ClipboardConfig = .init()
    private var monitorToken: ClipboardManager.MonitorToken?
    private var history: ClipboardHistory?
    private let log = Log.module("clipboard")

    func initialize(context: ModuleContext) async throws {
        let hist = await MainActor.run { ClipboardHistory() }
        self.history = hist
        await hist.updateConfig(
            maxItems: config.maxItems,
            excludePatterns: config.excludePatterns
        )
        await startMonitoring()
        let settings = "maxItems: \(config.maxItems), interval: \(config.pollingInterval)s"
        log.info("Clipboard module initialized (\(settings, privacy: .public))")
    }

    func teardown() async {
        let token = monitorToken
        await MainActor.run { token?.invalidate() }
        monitorToken = nil
        log.info("Clipboard module torn down")
    }

    func configDidUpdate(_ config: ClipboardConfig) async {
        let oldInterval = self.config.pollingInterval
        self.config = config
        let hist = history
        await MainActor.run {
            hist?.updateConfig(
                maxItems: config.maxItems,
                excludePatterns: config.excludePatterns
            )
        }
        if config.pollingInterval != oldInterval {
            let token = monitorToken
            await MainActor.run { token?.invalidate() }
            await startMonitoring()
            log.debug("Polling interval changed to \(config.pollingInterval, privacy: .public)s")
        }
    }

    static func validate(_ config: ClipboardConfig) -> ConfigValidationResult {
        var errors: [String] = []
        if config.maxItems < 1 || config.maxItems > 10000 {
            errors.append("maxItems must be between 1 and 10000")
        }
        if config.pollingInterval < 0.1 || config.pollingInterval > 5.0 {
            errors.append("pollingInterval must be between 0.1 and 5.0 seconds")
        }
        if let patterns = config.excludePatterns {
            for (index, pattern) in patterns.enumerated() {
                do {
                    _ = try NSRegularExpression(pattern: pattern)
                } catch {
                    errors.append("excludePatterns[\(index)] is invalid regex: \(error.localizedDescription)")
                }
            }
        }
        return errors.isEmpty ? .valid : .invalid(errors)
    }

    func provideActions(query: String, scoring: ScoringContext) async -> [any Action] {
        let cfg = config
        let hist = history
        let historyItems = await MainActor.run { hist?.items ?? [] }
        var actions: [any Action] = [buildPasteAction(itemCount: historyItems.count)]

        if cfg.showClearAction, !historyItems.isEmpty {
            actions.append(buildClearAction())
        }

        if let enabled = cfg.enabledActions {
            actions = actions.filter { enabled.contains($0.id.actionName) }
        }

        return actions
    }

    func provideParameterOptions(
        for parameterID: String,
        in actionID: ActionID,
        query: String
    ) async -> [ParameterOption] {
        guard parameterID == "item" else { return [] }
        let hist = history
        let items = await MainActor.run { hist?.items ?? [] }
        return items.map { item in
            ParameterOption(
                id: item.id,
                label: truncate(item.content, maxLength: 80),
                subtitle: "\(relativeTime(from: item.timestamp)) \u{2022} \(item.contentType.rawValue)",
                iconName: iconForContentType(item.contentType)
            )
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() async {
        let hist = history
        let interval = config.pollingInterval

        let token = await MainActor.run {
            ClipboardManager.startMonitoring(interval: interval) { content, sourceApp in
                hist?.addItem(content: content, sourceApp: sourceApp)
            }
        }
        self.monitorToken = token
    }

    // MARK: - Build Actions

    private func buildPasteAction(itemCount: Int) -> ClipboardAction {
        let hist = history
        let pasteOnSelect = config.pasteOnSelect
        let subtitle = itemCount == 0
            ? "No items in history"
            : "Choose from \(itemCount) item\(itemCount == 1 ? "" : "s")"
        return ClipboardAction(
            id: ActionID(module: "clipboard", name: "paste"),
            title: "Paste from Clipboard History",
            subtitle: subtitle,
            iconName: "doc.on.clipboard",
            relevanceScore: 0.9,
            keywords: ["clipboard", "paste", "copy", "history"],
            parameters: [
                ActionParameter(
                    id: "item",
                    label: "Clipboard Item",
                    type: .dynamicSelection(hint: "item"),
                    isRequired: true
                ),
            ],
            typesIntoFrontmostApp: pasteOnSelect
        ) { values in
            guard let itemID = values["item"] else {
                return .showResult(title: "Error", body: "No clipboard item selected")
            }
            let content: String? = await MainActor.run {
                hist?.items.first { $0.id == itemID }?.content
            }
            guard let content else {
                return .showResult(title: "Error", body: "Clipboard item not found")
            }
            await ClipboardManager.writeToPasteboard(content)
            if pasteOnSelect {
                await ClipboardManager.pasteFromPasteboard()
            }
            return .dismiss
        }
    }

    private func buildClearAction() -> ClipboardAction {
        let hist = history
        return ClipboardAction(
            id: ActionID(module: "clipboard", name: "clear"),
            title: "Clear Clipboard History",
            subtitle: "Remove all items from clipboard history",
            iconName: "trash",
            relevanceScore: 0.3,
            keywords: ["clear", "clipboard", "history", "delete", "remove"]
        ) { _ in
            await MainActor.run { hist?.clear() }
            return .showResult(
                title: "Clipboard Cleared",
                body: "All clipboard history items have been removed"
            )
        }
    }

    // MARK: - Helpers

    private func truncate(_ str: String, maxLength: Int) -> String {
        let firstLine = str.prefix(while: { $0 != "\n" && $0 != "\r" })
        if firstLine.count <= maxLength { return String(firstLine) }
        return String(firstLine.prefix(maxLength - 1)) + "\u{2026}"
    }

    private func iconForContentType(_ type: ClipboardContentType) -> String {
        switch type {
        case .text: "doc.plaintext"
        case .url: "link"
        case .filePath: "folder"
        }
    }

    private func relativeTime(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<10: return "just now"
        case ..<60: return "\(Int(elapsed))s ago"
        case ..<3600: return "\(Int(elapsed / 60))m ago"
        case ..<86400: return "\(Int(elapsed / 3600))h ago"
        case ..<172_800: return "yesterday"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}
