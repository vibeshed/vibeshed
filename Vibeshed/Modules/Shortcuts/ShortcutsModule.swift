import AppKit
import Foundation
import OSLog

/// The user's shortcuts, from the Shortcuts app. Every shortcut gets a row that runs it,
/// and Run Shortcut takes one by name, for keybindings and aliases.
///
/// Shortcuts in `searchFolder` are searches instead: picking one runs it with what's
/// typed next and lists what it outputs (see `ShortcutResultParser`), each result
/// opening its link. That brings other apps' content into the picker: a shortcut can use
/// Notes', Mail's or any app's own find actions, which macOS lets only Shortcuts call.
///
/// Listing runs the command-line tool a few times, so the list is cached and refreshed
/// in the background, at most every `refreshInterval`.
actor ShortcutsModule: ModuleConfigurable {
    let id = "shortcuts"
    let displayName = "Shortcuts"
    let iconName = "square.2.layers.3d"
    var isEnabled = true

    typealias Config = ShortcutsConfig
    static var defaultConfig: Config? {
        .init()
    }

    static let appPath = "/System/Applications/Shortcuts.app"
    /// How old the cached list gets before the next fetch lists shortcuts again.
    static let refreshInterval: TimeInterval = 30
    static let runPrefix = "run."
    static let searchPrefix = "search."

    private var config = ShortcutsConfig()
    private let log = Log.module("shortcuts")
    private var eventBus: EventBus?

    private var shortcuts: [ShortcutInfo] = []
    private var hasListing = false
    private var listedAt = Date.distantPast
    private var refreshTask: Task<Void, Never>?
    /// The run under way for each search shortcut, by its ID. A newer query cancels it.
    private var searches: [String: Task<[ShortcutResult], Error>] = [:]
    private var searchErrors: [String: Error] = [:]
    private let runner: any ShortcutsRunning

    init(runner: any ShortcutsRunning = ShortcutsCLI()) {
        self.runner = runner
    }

    func initialize(context: ModuleContext) async throws {
        eventBus = context.eventBus
        refresh()
        log.info("Shortcuts module initialized")
    }

    func teardown() async {
        searches.values.forEach { $0.cancel() }
        searches = [:]
        shortcuts = []
        hasListing = false
        listedAt = .distantPast
    }

    func configDidUpdate(_ config: ShortcutsConfig) async {
        self.config = config
    }

    static func validate(_ config: ShortcutsConfig) -> ConfigValidationResult {
        config.searchTimeout > 0 ? .valid : .invalid(["searchTimeout must be positive"])
    }

    func provideActions(query _: String, scoring _: ScoringContext) async -> [any Action] {
        if isStale, refreshTask == nil {
            refresh()
        }
        return actions()
    }

    /// Resolves before the first listing too, for keybindings checked at launch.
    func action(id: ActionID) async -> (any Action)? {
        if let action = actions().first(where: { $0.id == id }) {
            return action
        }
        guard !hasListing else { return nil }
        await refresh().value
        return actions().first { $0.id == id }
    }

    func provideParameterOptions(for parameterID: String, in actionID: ActionID, query: String) async
        -> [ParameterOption]
    {
        if !hasListing {
            await refresh().value
        }
        switch parameterID {
        case "shortcut":
            return visible.filter { !isSearch($0) }.map(Self.shortcutOption)
        case "result":
            guard let shortcut = visible.first(where: { Self.searchID(for: $0) == actionID }) else { return [] }
            return await search(shortcut, query: query)
        default:
            return []
        }
    }
}

// MARK: - Listing

extension ShortcutsModule {
    private var isStale: Bool {
        Date().timeIntervalSince(listedAt) > Self.refreshInterval
    }

    /// Lists shortcuts unless a listing is already under way, and returns it to wait on.
    @discardableResult
    private func refresh() -> Task<Void, Never> {
        if let refreshTask {
            return refreshTask
        }
        let task = Task { [self, runner] in
            let result: Result<[ShortcutInfo], Error>
            do {
                result = try await .success(runner.list())
            } catch {
                result = .failure(error)
            }
            await finishRefresh(result)
        }
        refreshTask = task
        return task
    }

    private func finishRefresh(_ result: Result<[ShortcutInfo], Error>) async {
        refreshTask = nil
        listedAt = Date()
        switch result {
        case let .success(listed):
            hasListing = true
            guard listed != shortcuts else { return }
            log.debug("Listed \(listed.count, privacy: .public) shortcuts")
            shortcuts = listed
            await eventBus?.publish(.moduleActionsChanged(moduleID: id))
        case let .failure(error):
            log.error("Failed to list shortcuts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var visible: [ShortcutInfo] {
        shortcuts.filter { !config.excluded.contains($0.name) }
    }

    private func isSearch(_ shortcut: ShortcutInfo) -> Bool {
        guard !config.searchFolder.isEmpty, let folder = shortcut.folder else { return false }
        return folder.caseInsensitiveCompare(config.searchFolder) == .orderedSame
    }

    /// A shortcut by identifier or, case aside, by name, listing shortcuts first if it isn't listed.
    private func shortcut(named nameOrID: String) async -> ShortcutInfo? {
        func find() -> ShortcutInfo? {
            shortcuts.first { $0.id == nameOrID }
                ?? shortcuts.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
        }
        if let found = find() {
            return found
        }
        await refresh().value
        return find()
    }
}

// MARK: - Actions

extension ShortcutsModule {
    func actions() -> [ShortcutsAction] {
        let rows = visible.map { isSearch($0) ? searchAction($0) : runAction($0) }
        return [runByNameAction()] + rows
    }

    private func runByNameAction() -> ShortcutsAction {
        ShortcutsAction(
            id: ActionID(module: "shortcuts", name: "run"),
            title: "Run Shortcut",
            subtitle: "Run one of your shortcuts",
            iconName: "play.fill",
            relevanceScore: 0.75,
            keywords: ["shortcut", "shortcuts", "run", "automation", "workflow"],
            parameters: [
                ActionParameter(
                    id: "shortcut", label: "Shortcut", type: .dynamicSelection(hint: "shortcut"), isRequired: true
                ),
            ]
        ) { [self] values in
            let picked = values["shortcut"] ?? ""
            guard let shortcut = await shortcut(named: picked) else {
                throw ShortcutsError.notFound(picked)
            }
            return try await run(shortcut)
        }
    }

    private func runAction(_ shortcut: ShortcutInfo) -> ShortcutsAction {
        ShortcutsAction(
            id: ActionID(module: "shortcuts", name: Self.runPrefix + StableID.hash(shortcut.id)),
            title: shortcut.name,
            subtitle: shortcut.folder.map { "Shortcut in \($0)" } ?? "Shortcut",
            iconName: "square.2.layers.3d",
            relevanceScore: 0.65,
            keywords: titleKeywords(shortcut.name) + ["shortcut"]
        ) { [self] _ in
            try await run(shortcut)
        }
    }

    private func searchAction(_ shortcut: ShortcutInfo) -> ShortcutsAction {
        ShortcutsAction(
            id: Self.searchID(for: shortcut),
            title: shortcut.name,
            subtitle: "Search with a shortcut",
            iconName: "magnifyingglass",
            relevanceScore: 0.7,
            keywords: titleKeywords(shortcut.name) + ["shortcut", "search"],
            parameters: [
                ActionParameter(
                    id: "result",
                    label: shortcut.name,
                    type: .dynamicSelection(hint: "result"),
                    isRequired: true,
                    rankedByModule: true
                ),
            ]
        ) { [self] values in
            // The only row without an ID is the one saying the shortcut failed.
            guard let picked = values["result"].flatMap(PickedResult.init(optionID:)) else {
                throw await searchError(for: shortcut) ?? ShortcutsError.failed("")
            }
            await open(picked)
            return .dismiss
        }
    }

    static func searchID(for shortcut: ShortcutInfo) -> ActionID {
        ActionID(module: "shortcuts", name: searchPrefix + StableID.hash(shortcut.id))
    }

    static func shortcutOption(_ shortcut: ShortcutInfo) -> ParameterOption {
        ParameterOption(
            id: shortcut.id,
            label: shortcut.name,
            subtitle: shortcut.folder,
            iconURL: URL(fileURLWithPath: appPath),
            keywords: titleKeywords(shortcut.name)
        )
    }

    /// Runs a shortcut with no input. Text it outputs is shown, a list's items a line each;
    /// anything else (an image, say) isn't.
    private func run(_ shortcut: ShortcutInfo) async throws -> ActionResult {
        let items = try await runner.run(shortcut.id, input: nil, timeout: nil)
        let text = items.compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { return .dismiss }
        return .showResult(title: shortcut.name, body: String(text.prefix(2000)))
    }
}

// MARK: - Searching

extension ShortcutsModule {
    /// Runs a search shortcut with `query` as its input, after stopping the run an
    /// earlier query started. A run that fails comes back as one row saying why.
    private func search(_ shortcut: ShortcutInfo, query: String) async -> [ParameterOption] {
        searches[shortcut.id]?.cancel()
        let timeout = config.searchTimeout
        let task = Task { [runner] in
            try await ShortcutResultParser.results(runner.run(shortcut.id, input: query, timeout: timeout))
        }
        searches[shortcut.id] = task
        defer {
            if searches[shortcut.id] == task {
                searches[shortcut.id] = nil
            }
        }
        do {
            let results = try await task.value
            searchErrors[shortcut.id] = nil
            return results.enumerated().map { Self.resultOption($1, index: $0) }
        } catch is CancellationError {
            return []
        } catch {
            searchErrors[shortcut.id] = error
            log.error("\(shortcut.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return [Self.failureOption(error, shortcut: shortcut)]
        }
    }

    private func searchError(for shortcut: ShortcutInfo) -> Error? {
        searchErrors[shortcut.id]
    }

    static func resultOption(_ result: ShortcutResult, index: Int) -> ParameterOption {
        ParameterOption(
            id: PickedResult(result).optionID(index: index),
            label: result.title,
            subtitle: result.subtitle ?? result.url.map { $0.host ?? $0.absoluteString },
            iconName: result.icon ?? (result.url == nil ? "doc.on.doc" : "link")
        )
    }

    static func failureOption(_ error: Error, shortcut: ShortcutInfo) -> ParameterOption {
        ParameterOption(
            id: "",
            label: "\u{201C}\(shortcut.name)\u{201D} didn't finish",
            subtitle: error.localizedDescription,
            iconName: "exclamationmark.triangle"
        )
    }

    /// Web links go through URL routing, the way a link clicked anywhere would, so
    /// `openInApps` and the rules apply; other links open in their app. Text is copied.
    private func open(_ picked: PickedResult) async {
        switch picked {
        case let .link(url):
            if let eventBus, ["http", "https"].contains(url.scheme?.lowercased()) {
                await eventBus.publish(.openURL(url))
            } else {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
        case let .text(text):
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

/// A picked search result, carried in its option's ID: options are listed again on every
/// keystroke, so the ID is all there is to go back to.
enum PickedResult: Equatable {
    case link(URL)
    case text(String)

    init(_ result: ShortcutResult) {
        self = result.url.map(Self.link) ?? .text(result.text ?? result.title)
    }

    /// The index keeps IDs apart when two results share a link.
    func optionID(index: Int) -> String {
        switch self {
        case let .link(url): "\(index)\(Self.separator)link\(Self.separator)\(url.absoluteString)"
        case let .text(text): "\(index)\(Self.separator)text\(Self.separator)\(text)"
        }
    }

    init?(optionID: String) {
        let parts = optionID.split(separator: Self.separator, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        switch parts[1] {
        case "link":
            guard let url = URL(string: String(parts[2])) else { return nil }
            self = .link(url)
        case "text":
            self = .text(String(parts[2]))
        default:
            return nil
        }
    }

    private static let separator: Character = "\u{1F}"
}
