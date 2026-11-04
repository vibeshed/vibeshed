import AppKit
import Foundation
import OSLog

/// Safari's history, Favorites and iCloud Tabs, read from Safari's own files (Full
/// Disk Access): Search Safari History / Favorites / iCloud Tabs, plus Favorites and
/// iCloud Tabs as rows of the main search and the history pages matching what's typed.
///
/// History is indexed in memory and searched on every keystroke, so the module is
/// query-dependent. Each source is read again once its file (or SQLite write-ahead log)
/// changes: Favorites and iCloud Tabs on the spot, being small, history in the
/// background, with the old index answering until the new one lands.
actor SafariModule: ModuleConfigurable {
    let id = "safari"
    let displayName = "Safari"
    let iconName = "safari"
    var isEnabled = true

    typealias Config = SafariConfig
    static var defaultConfig: Config? {
        .init()
    }

    static var requiredPermissions: Set<Permission> {
        [.fullDiskAccess]
    }

    static var isQueryDependent: Bool {
        true
    }

    static let bundleID = "com.apple.Safari"
    static let historyPrefix = "history."
    static let favoritePrefix = "favorite."
    static let cloudTabPrefix = "cloudTab."
    /// Options listed by Search Safari History.
    static let searchLimit = 100

    var config = SafariConfig()
    private let log = Log.module("safari")
    private var eventBus: EventBus?
    private let files: SafariFiles
    private let thisMac: String?
    /// Opens a page; Safari itself outside tests.
    let opener: @Sendable (URL) throws -> Void
    /// Safari.app, for row icons.
    let safariPath: String?

    private(set) var history = SafariHistoryIndex.empty
    private var historySignature: FileSignature?
    private var historyLoad: Task<Void, Never>?
    private(set) var historyError: Error?

    private(set) var favorites: [SafariFavorite] = []
    private var favoritesSignature: FileSignature?
    private(set) var favoritesError: Error?

    private(set) var cloudTabs: [SafariCloudTab] = []
    private var cloudTabsSignature: FileSignature?
    private(set) var cloudTabsError: Error?

    init(
        files: SafariFiles = SafariFiles(),
        thisMac: String? = SafariCloudTabsReader.currentComputerName(),
        safariPath: String? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariModule.bundleID)?.path,
        opener: @escaping @Sendable (URL) throws -> Void = {
            try BrowserRegistry.open(url: $0, browser: SafariModule.bundleID, profile: nil)
        }
    ) {
        self.files = files
        self.thisMac = thisMac
        self.safariPath = safariPath
        self.opener = opener
    }

    func initialize(context: ModuleContext) async throws {
        eventBus = context.eventBus
        refreshHistoryIfChanged()
        log.info("Safari module initialized")
    }

    func teardown() async {
        historyLoad?.cancel()
        historyLoad = nil
        history = .empty
        historySignature = nil
        favorites = []
        favoritesSignature = nil
        cloudTabs = []
        cloudTabsSignature = nil
    }

    func configDidUpdate(_ config: SafariConfig) async {
        self.config = config
    }

    static func validate(_ config: SafariConfig) -> ConfigValidationResult {
        config.historyResults < 0 ? .invalid(["historyResults must be non-negative"]) : .valid
    }

    func provideActions(query: String, scoring _: ScoringContext) async -> [any Action] {
        refreshFavoritesIfChanged()
        refreshCloudTabsIfChanged()
        refreshHistoryIfChanged()
        var actions = fixedActions()
        if config.showFavorites {
            actions += favorites.map(favoriteAction)
        }
        if config.showCloudTabs {
            actions += cloudTabs.map(cloudTabAction)
        }
        if config.historyResults > 0,
           query.trimmingCharacters(in: .whitespaces).count >= WordPrefixMatch.minimumQueryLength
        {
            actions += history.search(query, mode: .wordPrefix, limit: config.historyResults).map(historyAction)
        }
        return enabled(actions)
    }

    /// Resolves fixed actions and rows without a query, for keybindings, aliases and URIs.
    func action(id: ActionID) async -> (any Action)? {
        guard id.moduleID == self.id else { return nil }
        let name = id.actionName
        var found: SafariAction?
        if name.hasPrefix(Self.historyPrefix) {
            await loadHistoryIfNeeded()
            found = history.entry(hash: String(name.dropFirst(Self.historyPrefix.count))).map {
                historyAction(SafariHistoryIndex.Match(entry: $0, rank: 0, frecency: 0.5))
            }
        } else if name.hasPrefix(Self.favoritePrefix) {
            refreshFavoritesIfChanged()
            found = favorites.lazy.map(favoriteAction).first { $0.id == id }
        } else if name.hasPrefix(Self.cloudTabPrefix) {
            refreshCloudTabsIfChanged()
            found = cloudTabs.lazy.map(cloudTabAction).first { $0.id == id }
        } else {
            found = fixedActions().first { $0.id == id }
        }
        return found.flatMap { enabled([$0]).first }
    }

    /// `enabledActions` takes full names (`searchHistory`) or the row families
    /// (`history`, `favorite`, `cloudTab`).
    func enabled(_ actions: [SafariAction]) -> [SafariAction] {
        guard let enabled = config.enabledActions else { return actions }
        return actions.filter { action in
            let name = action.id.actionName
            return enabled.contains(name) || enabled.contains(String(name.prefix { $0 != "." }))
        }
    }

    func open(_ url: String) throws {
        guard let target = URL(string: url) else { throw SafariModuleError.badAddress(url) }
        try opener(target)
    }
}

enum SafariModuleError: LocalizedError {
    case badAddress(String)
    case nothingChosen

    var errorDescription: String? {
        switch self {
        case let .badAddress(url): "Safari can't open \(url)"
        case .nothingChosen: "Nothing to open"
        }
    }
}

// MARK: - Loading

extension SafariModule {
    /// Waits for history to be read when it never was, or its files changed since.
    func loadHistoryIfNeeded() async {
        await refreshHistoryIfChanged()?.value
    }

    /// Starts reading history in the background when its files changed since the last
    /// read, and returns that read (or one already under way) to wait on.
    @discardableResult
    func refreshHistoryIfChanged() -> Task<Void, Never>? {
        if let historyLoad {
            return historyLoad
        }
        let signature = FileSignature(files.history, database: true)
        guard signature != historySignature else { return nil }
        let path = files.history
        let task = Task { [self] in
            let start = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                Result { SafariHistoryIndex(entries: try SafariHistoryReader.read(at: path)) }
            }.value
            await finishHistoryLoad(result, signature: signature, took: ContinuousClock.now - start)
        }
        historyLoad = task
        return task
    }

    private func finishHistoryLoad(
        _ result: Result<SafariHistoryIndex, Error>,
        signature: FileSignature,
        took: Duration
    ) async {
        historyLoad = nil
        historySignature = signature
        switch result {
        case let .success(index):
            log.debug("Indexed \(index.count, privacy: .public) history pages in \(took, privacy: .public)")
            historyError = nil
            let changed = index.count != history.count || index.entries.first != history.entries.first
            history = index
            if changed {
                await eventBus?.publish(.moduleActionsChanged(moduleID: id))
            }
        case let .failure(error):
            // Kept: the last index is still worth searching.
            historyError = error
            log.error("Couldn't read Safari history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshFavoritesIfChanged() {
        let signature = FileSignature(files.bookmarks)
        guard signature != favoritesSignature else { return }
        favoritesSignature = signature
        do {
            favorites = try SafariFavoritesReader.read(at: files.bookmarks)
            favoritesError = nil
        } catch {
            favoritesError = error
            log.error("Couldn't read Safari Favorites: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshCloudTabsIfChanged() {
        let path = files.cloudTabs
        let signature = FileSignature(path, database: true)
        guard signature != cloudTabsSignature else { return }
        cloudTabsSignature = signature
        do {
            cloudTabs = try SafariCloudTabsReader.read(at: path, thisMac: thisMac)
            cloudTabsError = nil
        } catch {
            cloudTabsError = error
            log.error("Couldn't read iCloud Tabs: \(error.localizedDescription, privacy: .public)")
        }
    }
}
