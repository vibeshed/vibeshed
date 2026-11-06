import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// The files Finder lists under Recents: Search Recent Files, plus the recent files
/// matching what's typed as rows of the main search. Each opens in its default app.
///
/// The list comes from Finder's own Spotlight query, kept running and indexed in memory,
/// so it needs no permission and reads no file. It only knows files opened through
/// LaunchServices (Finder, the `open` command, an app's Open dialog): one opened from
/// inside an editor or a terminal mostly isn't there, as it isn't in Finder's Recents.
actor RecentFilesModule: ModuleConfigurable {
    let id = "recentFiles"
    let displayName = "Recent Files"
    let iconName = "doc.badge.clock"
    var isEnabled = true

    typealias Config = RecentFilesConfig
    static var defaultConfig: Config? {
        .init()
    }

    static var isQueryDependent: Bool {
        true
    }

    static let filePrefix = "file."
    /// Options listed by Search Recent Files.
    static let searchLimit = 200

    var config = RecentFilesConfig()
    private let log = Log.module("recentFiles")
    private var eventBus: EventBus?
    private let source: any RecentFilesSource
    private let home: String
    /// Opens a file in its default app; NSWorkspace outside tests.
    let opener: @Sendable (URL) -> Bool
    /// The app that opens a type by default, for the selected row's icon and the preview.
    private let appForType: @Sendable (UTType) -> String?

    /// Every file Finder's Recents lists, most recently used first.
    private(set) var files: [RecentFile] = []
    /// `files` without the excluded folders.
    private(set) var index = RecentFilesIndex.empty
    private(set) var hasLoaded = false
    private(set) var sourceError: Error?
    private var watcher: Task<Void, Never>?
    private var defaultApps: [String: String?] = [:]

    init(
        source: any RecentFilesSource = SpotlightRecentFiles(),
        home: String = NSHomeDirectory(),
        appForType: @escaping @Sendable (UTType) -> String? = {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.path
        },
        opener: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.source = source
        self.home = home
        self.appForType = appForType
        self.opener = opener
    }

    func initialize(context: ModuleContext) async throws {
        eventBus = context.eventBus
        startWatching()
        log.info("Recent Files module initialized")
    }

    func teardown() async {
        watcher?.cancel()
        watcher = nil
        source.stop()
        files = []
        index = .empty
        hasLoaded = false
        sourceError = nil
        defaultApps = [:]
    }

    func configDidUpdate(_ config: RecentFilesConfig) async {
        let reindex = config.excludedFolders != self.config.excludedFolders
        self.config = config
        if reindex {
            rebuildIndex()
        }
    }

    static func validate(_ config: RecentFilesConfig) -> ConfigValidationResult {
        config.fileResults < 0 ? .invalid(["fileResults must be non-negative"]) : .valid
    }

    func provideActions(query: String, scoring _: ScoringContext) async -> [any Action] {
        var actions = fixedActions()
        if config.fileResults > 0,
           query.trimmingCharacters(in: .whitespaces).count >= WordPrefixMatch.minimumQueryLength
        {
            actions += index.search(query, mode: .wordPrefix, limit: config.fileResults).map(fileAction)
        }
        return enabled(actions)
    }

    /// Resolves the search action and file rows without a query, for keybindings,
    /// aliases and URIs.
    func action(id: ActionID) async -> (any Action)? {
        guard id.moduleID == self.id else { return nil }
        let name = id.actionName
        let found: RecentFilesAction?
        if name.hasPrefix(Self.filePrefix) {
            await waitForFirstLoad()
            found = index.file(hash: String(name.dropFirst(Self.filePrefix.count))).map { file in
                fileAction(.init(file: file, rank: 0, recency: RecentFilesIndex.recency(of: file, now: Date())))
            }
        } else {
            found = fixedActions().first { $0.id == id }
        }
        return found.flatMap { enabled([$0]).first }
    }

    /// `enabledActions` takes full names (`searchFiles`) or the row family (`file`).
    func enabled(_ actions: [RecentFilesAction]) -> [RecentFilesAction] {
        guard let enabled = config.enabledActions else { return actions }
        return actions.filter { action in
            let name = action.id.actionName
            return enabled.contains(name) || enabled.contains(String(name.prefix { $0 != "." }))
        }
    }

    /// Opens a file the list holds. Nothing else: a URI could name any path, and opening
    /// a script runs it.
    func open(_ path: String) throws {
        guard index.contains(path: path) else { throw RecentFilesError.notRecent(path) }
        guard opener(URL(fileURLWithPath: path)) else {
            throw RecentFilesError.couldNotOpen((path as NSString).lastPathComponent)
        }
    }

    /// The app that opens `file` by default, looked up once per type.
    func defaultApp(for file: RecentFile) -> String? {
        let key = file.type.identifier
        if let cached = defaultApps[key] {
            return cached
        }
        let app = appForType(file.type)
        defaultApps[key] = app
        return app
    }
}

// MARK: - Watching

extension RecentFilesModule {
    /// Waits, briefly, for Spotlight's first answer: for a keybinding or a search used
    /// right after launch. Spotlight gathers Finder's Recents in well under a second.
    func waitForFirstLoad() async {
        for _ in 0 ..< 40 where !hasLoaded {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startWatching() {
        watcher?.cancel()
        let stream = source.start()
        watcher = Task { [weak self] in
            for await result in stream {
                await self?.receive(result)
            }
        }
    }

    private func receive(_ result: Result<[RecentFile], Error>) async {
        switch result {
        case let .success(found):
            sourceError = nil
            let changed = !hasLoaded || found != files
            files = found
            hasLoaded = true
            guard changed else { return }
            log.debug("Recent files: \(found.count, privacy: .public)")
            // A file just opened may be of a type whose default app changed since.
            defaultApps = [:]
            rebuildIndex()
            await eventBus?.publish(.moduleActionsChanged(moduleID: id))
        case let .failure(error):
            // Kept: the last list is still worth searching.
            sourceError = error
            hasLoaded = true
            log.error("Couldn't list recent files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuildIndex() {
        let excluded = config.excludedPrefixes(home: home)
        index = RecentFilesIndex(files: excluded.isEmpty ? files : files.filter { file in
            !excluded.contains { file.path.hasPrefix($0) }
        })
    }
}
