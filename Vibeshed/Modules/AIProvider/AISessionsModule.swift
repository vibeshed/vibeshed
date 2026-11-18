import Foundation
import OSLog

/// Generic module for AI vendors that surface resumable sessions. Specialized per
/// vendor by an `AIProvider` (Anthropic, OpenAI). Owns caching, ranking, the search
/// action and `enabledActions` filtering so vendor code is only discovery + reopen.
actor AISessionsModule<Provider: AIProvider>: ModuleConfigurable {
    typealias Config = Provider.Config

    let id: String
    let displayName: String
    let iconName: String
    var isEnabled = true

    static var defaultConfig: Config? {
        Provider.defaultConfig
    }

    static func validate(_ config: Config) -> ConfigValidationResult {
        Provider.validate(config)
    }

    private let provider: Provider
    private var config: Config
    private var cache: TimedCache<[AISession]>
    private let log: Logger

    /// CLI sessions start and resume in a new tab of the configured terminal.
    var automationTargets: [String] {
        [AILaunch.terminalBundleID(for: config.terminalApp)]
    }

    init() {
        provider = Provider()
        id = Provider.moduleID
        displayName = Provider.displayName
        iconName = Provider.iconName
        config = Provider.defaultConfig
        cache = TimedCache(ttl: Provider.cacheTTL)
        log = Log.module(Provider.moduleID)
    }

    func initialize(context _: ModuleContext) async throws {
        refreshCache()
        let count = cache.value?.count ?? 0
        log.info(
            "\(self.displayName, privacy: .public) module initialized (\(count, privacy: .public) sessions found)"
        )
    }

    func teardown() async {
        cache.invalidate()
    }

    func configDidUpdate(_ config: Config) async {
        self.config = config
        refreshCache()
        log.debug("Config updated, cache refreshed (\(self.cache.value?.count ?? 0, privacy: .public) sessions)")
    }

    func provideActions(
        query _: String,
        scoring _: ScoringContext
    ) async -> [any Action] {
        buildActions()
    }

    // MARK: - Cache

    private func currentSessions() -> [AISession] {
        if let cached = cache.value { return cached }
        refreshCache()
        return cache.value ?? []
    }

    private func refreshCache() {
        cache.store(
            provider.readSessions(config: config, limit: config.maxResults)
        )
    }

    // MARK: - Action building

    private func buildActions() -> [any Action] {
        var actions = [searchAction()]
        actions.append(contentsOf: sessionActions())
        if config.showLaunchers {
            actions.append(contentsOf: provider.launcherActions(config: config))
        }
        if let enabled = config.enabledActions {
            actions = actions.filter { enabled.contains($0.id.actionName) }
        }
        return actions
    }

    private func sessionActions() -> [AIAction] {
        let sessions = currentSessions()
        return zip(sessions, primaryRows(for: sessions)).flatMap { session, action in
            [action] + provider.alternateActions(for: session, config: config)
        }
    }

    /// One row per session that reopens it the default way, ranked in list order.
    private func primaryRows(for sessions: [AISession]) -> [AIAction] {
        sessions.enumerated().map { index, session in
            makeSessionAction(
                session,
                namePrefix: "session",
                relevanceScore: rankedScore(index: index)
            )
        }
    }

    private func makeSessionAction(
        _ session: AISession,
        namePrefix: String,
        relevanceScore: Double
    ) -> AIAction {
        let provider = self.provider
        let config = self.config
        return .forSession(
            session,
            module: Provider.identity,
            namePrefix: namePrefix,
            relevanceScore: relevanceScore
        ) {
            provider.openSession(session, config: config)
        }
    }

    // MARK: - Search

    /// Searches the vendor's full history rather than the cached head of the list,
    /// so sessions past `maxResults` are still reachable by name.
    private func searchAction() -> AIAction {
        let provider = self.provider
        let config = self.config
        let moduleID = id
        let moduleName = displayName
        return AIAction(
            id: ActionID(module: moduleID, name: "search"),
            title: "Search \(displayName) Sessions",
            subtitle: "Search across \(displayName) session history",
            iconName: "magnifyingglass",
            relevanceScore: 0.9,
            keywords: ["ai", "search", "session", "history", moduleID],
            parameters: [
                ActionParameter(
                    id: "query",
                    label: "Search Query",
                    type: .text(placeholder: "Search sessions..."),
                    isRequired: true
                ),
            ],
            moduleName: moduleName,
            itemType: .search
        ) { values in
            guard let query = values["query"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !query.isEmpty
            else {
                return .showResult(
                    title: "Search \(moduleName) Sessions",
                    body: "Please enter a search query"
                )
            }
            let matches = provider
                .readSessions(config: config, limit: config.maxResults * 3)
                .filter { $0.matches(lowercasedQuery: query.lowercased()) }
            guard !matches.isEmpty else {
                return .showResult(
                    title: "No Results",
                    body: "No \(moduleName) sessions matching \"\(query)\""
                )
            }
            let results = matches
                .prefix(config.maxResults)
                .enumerated()
                .map { index, session in
                    AIAction.forSession(
                        session,
                        module: Provider.identity,
                        namePrefix: "result",
                        relevanceScore: rankedScore(index: index, step: 0.03)
                    ) {
                        provider.openSession(session, config: config)
                    }
                }
            return .pushActions(results)
        }
    }
}

extension AISessionsModule: AISessionListing {
    /// The primary row of each cached session, without the alternate-surface rows and
    /// whatever `enabledActions` keeps: the cross-vendor list asked for sessions.
    func recentSessionActions() -> [AIAction] {
        primaryRows(for: currentSessions())
    }
}
