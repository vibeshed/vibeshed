import Combine
import CoreFoundation
import Foundation

@MainActor
@Observable
final class PickerCoordinator {
    // Internal (not private) for the live-preview extension in PickerCoordinator+LivePreview.
    let pickerState: PickerState
    let moduleRegistry: ModuleRegistry
    let panelController: PanelController
    private let eventBus: EventBus
    var usageTracker: UsageTracker?
    var aliasManager: AliasManager?
    var layoutTransliterator: (any LayoutCorrecting)?

    private var currentContext: SystemContext?
    /// Internal for PickerCoordinator+ParameterOptions, as is `parameterOptionsGeneration`.
    var parameterQuerySubscription: AnyCancellable?
    private var querySubscription: AnyCancellable?
    private var actionRefreshTask: Task<Void, Never>?

    // MARK: - Empty-query cache (instant display on re-open)

    @ObservationIgnored private var cachedEmptyQueryItems: [ActionItem]?
    @ObservationIgnored private var cachedEmptyQueryActionCache: [ActionID: any Action]?

    // MARK: - Catalog corpus (query-independent actions, scored per keystroke)

    /// Actions from catalog modules with precomputed search text. Fetched on panel
    /// show and on module-change events; keystrokes only re-score this cache plus
    /// the (cheap) query-dependent modules.
    @ObservationIgnored private var catalogCorpus: [ScorableAction]?

    /// Monotonic id for query pipeline runs. Each `runQuery` (and a fresh open's
    /// cached list) claims the next value; results whose generation is no longer
    /// current are dropped, so a slow older query can never overwrite a newer one's results.
    @ObservationIgnored private var queryGeneration = 0
    /// The text the newest generation ranks: the list on screen, or the one the run
    /// in flight will show. nil when nothing has ranked the open picker's list yet.
    @ObservationIgnored private var rankedQuery: String?
    @ObservationIgnored private var runningQueryTask: Task<Void, Never>?
    /// The same guard for dynamic parameter options, whose fetches (e.g. `brew search`)
    /// can finish out of order.
    @ObservationIgnored var parameterOptionsGeneration = 0

    // MARK: - Live parameter preview (see PickerCoordinator+LivePreview)

    @ObservationIgnored var livePreview: LivePreviewSession?
    @ObservationIgnored let livePreviewScheduler = LivePreviewScheduler()
    /// The action picked from the search list and what was typed to find it, for the
    /// usage tracker's query history once its parameters are filled in.
    @ObservationIgnored private var pick: (actionID: ActionID, query: String)?

    init(
        pickerState: PickerState,
        moduleRegistry: ModuleRegistry,
        panelController: PanelController,
        eventBus: EventBus
    ) {
        self.pickerState = pickerState
        self.moduleRegistry = moduleRegistry
        self.panelController = panelController
        self.eventBus = eventBus
    }

    // MARK: - Public API

    /// Shows the picker in parameter-input mode for the given action.
    /// Called from keybinding executor when an action has required parameters. The step
    /// opens on a fresh picker with nothing beneath it, so Escape closes it.
    func showForParameterInput(action: any Action) {
        panelController.show(fresh: true)
        pickerState.enterParameterMode(action: action, asRoot: true)
        // Trigger initial fetch for dynamicSelection
        if let param = pickerState.currentParameter,
           case .dynamicSelection = param.type
        {
            fetchParameterOptions(for: param, actionID: action.id, query: "")
        }
    }

    // MARK: - Setup

    func start() {
        wireQueryToModules()
        wireParameterQuery()
        wireActionRefresh()
        pickerState.onLivePreviewContextChange = { [weak self] in self?.syncLivePreview() }
        pickerState.onParameterQueryEdit = { [weak self] in self?.livePreviewScheduler.filterEdited() }
    }

    // MARK: - Keyboard handlers

    /// `keepOpen` (Shift held: ⇧Return, ⇧double-click, ⌘⇧1–9) runs the action without closing
    /// the picker. Only what was typed is cleared, so similar actions (several cask
    /// installs) can be fired one after another.
    func handleReturn(keepOpen: Bool = false) {
        switch pickerState.mode {
        case .search, .pushedActions:
            handleReturnInActionList(keepOpen: keepOpen)
        case .parameterInput:
            handleReturnInParameterMode(keepOpen: keepOpen)
        }
    }

    /// Backspace on an empty field, or the ✕ on the action's pill: back one level. A step
    /// with nothing beneath it (a keybinding's) gives way to a fresh search instead.
    @discardableResult
    func goBack() -> Task<Void, Never>? {
        guard !pickerState.popMode(), pickerState.mode.isParameterStep else { return nil }
        pickerState.showAsRoot(.search)
        return loadInitialActions()
    }

    func handleTab() {
        guard case let .parameterInput(_, parameterIndex) = pickerState.mode else { return }
        // Skip current optional parameter and advance
        pickerState.advanceToNextParameter(startingFrom: parameterIndex + 1)
        if pickerState.allRequiredParametersFilled {
            executeActiveAction()
        }
    }

    func handleCmdNumber(_ number: Int, keepOpen: Bool = false) {
        let index = number - 1
        switch pickerState.mode {
        case .search, .pushedActions:
            activateAction(at: index, keepOpen: keepOpen)
        case .parameterInput:
            guard index < pickerState.parameterOptions.count else { return }
            pickerState.selectedParameterOptionID = pickerState.parameterOptions[index].id
            handleReturnInParameterMode(keepOpen: keepOpen)
        }
    }

    // MARK: - Return handlers per mode

    private func handleReturnInActionList(keepOpen: Bool) {
        guard let selectedID = pickerState.selectedActionID,
              let idx = pickerState.actions.firstIndex(where: { $0.id == selectedID })
        else { return }
        activateAction(at: idx, keepOpen: keepOpen)
    }

    /// Activate an action by ID — used by mouse-click handlers in the list view.
    func activateAction(id: ActionID, keepOpen: Bool = false) {
        switch pickerState.mode {
        case .search, .pushedActions:
            break
        case .parameterInput:
            return
        }
        guard let idx = pickerState.actions.firstIndex(where: { $0.id == id }) else { return }
        activateAction(at: idx, keepOpen: keepOpen)
    }

    private func activateAction(at index: Int, keepOpen: Bool = false) {
        guard index >= 0, index < pickerState.actions.count else { return }
        let targetItem = pickerState.actions[index]
        pickerState.selectedActionID = targetItem.id
        pickerState.bumpActivation(for: targetItem.id)
        guard let action = pickerState.actionCache[targetItem.id] else { return }

        // Activating a message dismisses it as Escape does: back to the Shift-run session it
        // covers, or closed. Running it like an action would close and reset that session.
        if action is PickerMessageAction {
            if !pickerState.popMode() {
                panelController.close()
            }
            return
        }

        // Read before a Shift run clears the field.
        pick = pickerState.mode == .search ? (action.id, pickerState.rankedText) : nil
        let requiredParams = action.parameters.filter(\.isRequired)
        if requiredParams.isEmpty {
            if keepOpen { pickerState.prepareForAnotherRun() }
            let query = pick?.query
            Task { await executeAction(action, values: [:], keepOpen: keepOpen, pickedFor: query) }
        } else {
            pickerState.enterParameterMode(action: action)
            // Trigger initial fetch for dynamicSelection
            if let param = pickerState.currentParameter,
               case .dynamicSelection = param.type
            {
                fetchParameterOptions(for: param, actionID: action.id, query: "")
            }
        }
    }

    private func handleReturnInParameterMode(keepOpen: Bool = false) {
        guard let param = pickerState.currentParameter,
              let value = param.confirmableValue(
                  typed: pickerState.parameterQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  selectedOptionID: pickerState.selectedParameterOptionID
              )
        else { return }
        pickerState.confirmParameterValue(value, forParameterID: param.id)
        if value == pickerState.selectedParameterOptionID {
            pickerState.bumpActivation(forOption: value)
        }

        // Check if all required params are filled
        if pickerState.allRequiredParametersFilled {
            executeActiveAction(keepOpen: keepOpen)
        } else if let nextIndex = pickerState.nextUnfilledParameterIndex {
            pickerState.advanceToNextParameter(startingFrom: nextIndex)
            // Trigger fetch for dynamicSelection
            if let nextParam = pickerState.currentParameter,
               case .dynamicSelection = nextParam.type,
               let action = pickerState.activeAction
            {
                fetchParameterOptions(for: nextParam, actionID: action.id, query: "")
            }
        }
    }

    // MARK: - Action execution

    private func executeActiveAction(keepOpen: Bool = false) {
        guard let action = pickerState.activeAction else { return }
        let values = pickerState.collectedValues
        let query = pick?.actionID == action.id ? pick?.query : nil
        if keepOpen { pickerState.prepareForAnotherRun() }
        // Close any live preview as committed *before* the reset in executeAction
        // would end it as cancelled — the module must keep, not revert, the choice.
        let previewEnded = endLivePreview(committed: true)
        Task {
            await previewEnded?.value
            await executeAction(action, values: values, keepOpen: keepOpen, pickedFor: query)
        }
    }

    // executeAction and its result handling live in PickerCoordinator+ActionExecution.

    // MARK: - Query wiring

    private func wireQueryToModules() {
        querySubscription = pickerState.debouncedQuery
            .sink { [weak self] query in
                guard let self else { return }
                guard case .search = pickerState.mode else { return }
                // A repeat of what the newest run ranks changes nothing. Compared with
                // that, not the last debounced text: the initial load ranks text the
                // debounce never reported, e.g. "s" while "safari" is being typed.
                guard query != rankedQuery else { return }
                pickerState.isLoading = true
                runningQueryTask?.cancel()
                runningQueryTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Capture context lazily — only on the first query of a session.
                    await runQuery(query, options: .keystroke(captureContext: currentContext == nil))
                }
            }
    }

    /// Fetches the catalog (query-independent) actions, applies aliases, and
    /// precomputes lowercase search text off the main actor. Stores the result
    /// as the corpus that per-keystroke scoring runs against.
    private func fetchCatalogCorpus(scoring: ScoringContext) async -> [ScorableAction] {
        let fetchState = Log.signposter.beginInterval("FetchCatalogCorpus")
        defer { Log.signposter.endInterval("FetchCatalogCorpus", fetchState) }

        let actions = await moduleRegistry.catalogActions(scoring: scoring)

        // Apply aliases: enrich keywords for parameterless aliases,
        // create synthetic actions for parameterized ones. Cheap; stays on main actor.
        let aliasResult = aliasManager?.applyAliases(to: actions)
        let enrichments = aliasResult?.keywordEnrichments ?? [:]
        let synthetics: [any Action] = aliasResult?.syntheticActions ?? []

        let corpus = await Task.detached {
            (actions + synthetics).map {
                ScorableAction(action: $0, extraKeywords: enrichments[$0.id] ?? [])
            }
        }.value
        catalogCorpus = corpus
        return corpus
    }

    /// Queries query-dependent modules (e.g. math), merges with the cached corpus,
    /// and scores/ranks off the main actor — the per-keystroke hot path.
    /// `combined` is everything that was scored (the debug dump re-ranks it uncapped).
    func scoreQuery(
        _ query: String,
        corpus: [ScorableAction],
        scoring: ScoringContext
    ) async -> (items: [ActionItem], cache: [ActionID: any Action], combined: [ScorableAction]) {
        let buildState = Log.signposter.beginInterval("BuildActionItems")
        defer { Log.signposter.endInterval("BuildActionItems", buildState) }

        let searchResults = await moduleRegistry.searchActions(query: query, scoring: scoring)
        return await Task.detached {
            let combined = corpus + searchResults.map { ScorableAction(action: $0) }
            let (items, cache) = ActionScorer.scoreAndRank(corpus: combined, query: query, scoring: scoring)
            return (items, cache, combined)
        }.value
    }

    // MARK: - Unified query pipeline

    func makeScoring(query: String, context: SystemContext?) -> ScoringContext {
        usageTracker?.makeScoringContext(query: query, systemContext: context)
            ?? ScoringContext(usageCounts: [:], lastUsedDates: [:], query: query, systemContext: context)
    }

    /// Single query → score → display pipeline shared by all four entry points
    /// (debounced typing, initial load, refresh-in-place, dynamic refresh).
    /// `options` captures the only differences between them.
    private func runQuery(_ query: String, options: QueryOptions) async {
        let pipelineState = Log.signposter.beginInterval("QueryPipeline")
        defer { Log.signposter.endInterval("QueryPipeline", pipelineState) }

        let generation = claimGeneration(ranking: query)
        // Stale-guard: a later runQuery superseded this one during an await,
        // or the picker left search mode. Results must be dropped, not displayed.
        func isCurrent() -> Bool {
            guard generation == queryGeneration else { return false }
            guard case .search = pickerState.mode else { return false }
            return true
        }

        if options.captureContext {
            currentContext = SystemContext.capture()
        }
        let ctx = currentContext

        func finish(
            _ items: [ActionItem],
            _ cache: [ActionID: any Action],
            scored combined: [ScorableAction],
            _ scoring: ScoringContext
        ) {
            pickerState.updateActions(items, cache: cache, rankedFor: query)
            ActionListDebugDump.schedule(query: query, displayed: items, corpus: combined, scoring: scoring)
            if options.clearsLoading { pickerState.isLoading = false }
            if options.updatesEmptyCacheWhenEmpty, query.isEmpty {
                cachedEmptyQueryItems = items
                cachedEmptyQueryActionCache = cache
            }
        }

        let scoring = makeScoring(query: query, context: ctx)

        let corpus: [ScorableAction]
        if options.refreshCorpus || catalogCorpus == nil {
            corpus = await fetchCatalogCorpus(scoring: scoring)
        } else {
            corpus = catalogCorpus ?? []
        }
        guard isCurrent() else { return }

        let (items, cache, combined) = await scoreQuery(query, corpus: corpus, scoring: scoring)
        guard isCurrent() else { return }

        // Layout correction fallback: nothing but catch-alls (web search) matched,
        // so retry the query as typed on the Latin layout.
        if !query.isEmpty, Self.topRankedScore(items, cache) == nil {
            let corrected = await bestLayoutCorrection(of: query, corpus: corpus, context: ctx)
            guard isCurrent() else { return }
            if let corrected {
                pickerState.layoutCorrectionHint = corrected.hint
                finish(corrected.items, corrected.cache, scored: corrected.combined, corrected.scoring)
                return
            }
        }

        pickerState.layoutCorrectionHint = nil
        finish(items, cache, scored: combined, scoring)
    }

    /// Supersedes every run still in flight for a list that ranks `query`.
    @discardableResult
    private func claimGeneration(ranking query: String?) -> Int {
        queryGeneration += 1
        rankedQuery = query
        return queryGeneration
    }
}

// MARK: - Dynamic action refresh

extension PickerCoordinator {
    private func wireActionRefresh() {
        actionRefreshTask = Task { [weak self] in
            guard let self else { return }
            let (_, stream) = await eventBus.subscribe()
            for await event in stream {
                switch event {
                case .moduleActionsChanged:
                    invalidateEmptyQueryCache()
                    if panelController.isVisible, case .search = pickerState.mode {
                        await refreshActions()
                    }
                case .configReloaded, .moduleRegistered, .moduleUnregistered:
                    invalidateEmptyQueryCache()
                default:
                    break
                }
            }
        }
    }

    func clearContext() {
        currentContext = nil
    }

    /// Shows cached empty-query results synchronously without triggering any async work.
    /// Called before the show animation so the user sees content immediately.
    ///
    /// Starts the session's ranking afresh: a run left over from the last session
    /// can't land on the new list, and that session's text isn't a repeat any more.
    func showCachedActionsIfAvailable() {
        if let cachedItems = cachedEmptyQueryItems,
           let cachedCache = cachedEmptyQueryActionCache
        {
            claimGeneration(ranking: "")
            // Not ranked for this session, so its first ranking starts on its own top row.
            pickerState.updateActions(cachedItems, cache: cachedCache)
            pickerState.isLoading = false
        } else {
            claimGeneration(ranking: nil)
            pickerState.isLoading = true
        }
    }

    /// Triggers an immediate (non-debounced) query to populate the action list.
    /// Called after the show animation completes so re-renders don't contend with animation.
    ///
    /// Ranks whatever the search field holds by then — usually "", but a
    /// `vibeshed://picker?q=` query or keys typed during the animation may already
    /// be there, and this run supersedes their debounced query.
    @discardableResult
    func loadInitialActions() -> Task<Void, Never> {
        // If no cache was shown before animation, show loading state
        if cachedEmptyQueryItems == nil {
            pickerState.isLoading = true
        }

        return Task { @MainActor [weak self] in
            guard let self else { return }
            await runQuery(pickerState.query, options: .initialLoad)
        }
    }

    /// Re-shows the picker with retained state. Refreshes context and re-scores
    /// existing actions in the background without clearing the list.
    func refreshInPlace() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runQuery(pickerState.query, options: .refreshInPlace)
        }
    }

    /// Invalidates the empty-query cache and the catalog corpus so the next
    /// query re-fetches from modules.
    private func invalidateEmptyQueryCache() {
        cachedEmptyQueryItems = nil
        cachedEmptyQueryActionCache = nil
        catalogCorpus = nil
    }

    func refreshActions() async {
        await runQuery(pickerState.query, options: .dynamicRefresh)
    }
}
