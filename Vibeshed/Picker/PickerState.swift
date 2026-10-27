import Combine
import Foundation
import OSLog
import SwiftUI

@MainActor
@Observable
final class PickerState {
    var query: String = "" {
        didSet { querySubject.send(query) }
    }

    var actions: [ActionItem] = []
    var selectedActionID: ActionID?
    var isLoading: Bool = false

    /// Bumped whenever a list update snaps the selection back to the first row.
    /// The list view watches it to scroll back to the top — `selectedActionID`
    /// alone can't signal that, since the new first row may carry the same ID.
    private(set) var listResetToken: Int = 0

    /// Bumped when a refresh keeps the selected row but moves it, so the list view
    /// scrolls it back into view; its ID is unchanged, so no selection `onChange` fires.
    private(set) var selectionRevealToken: Int = 0

    /// The search text the rows on screen were ranked for. nil when they aren't a
    /// ranking of the field: the cached list shown at open, pushed rows, a message.
    @ObservationIgnored private(set) var listQuery: String?

    // MARK: - Mode state machine

    var mode: PickerMode = .search {
        didSet { onLivePreviewContextChange?() }
    }

    /// The levels Escape goes back through, nearest last. Empty at the root: the
    /// search, or a list or step that came up on its own (see `showAsRoot`).
    private var modeStack: [CoveredLevel] = []

    /// Fired when anything a live parameter preview depends on changes (mode, highlighted
    /// option). The coordinator uses it to start, advance, or end the preview.
    @ObservationIgnored var onLivePreviewContextChange: (@MainActor () -> Void)?

    // MARK: - Parameter binding state

    var activeAction: (any Action)?
    var collectedValues: ParameterValues = [:]
    /// What the user picked or typed for each confirmed parameter, as shown (an option's
    /// label, not its ID). Defaults and skipped parameters have none.
    var collectedLabels: [String: String] = [:]
    var currentParameter: ActionParameter?
    var parameterOptions: [ParameterOption] = []
    var selectedParameterOptionID: String? {
        didSet { onLivePreviewContextChange?() }
    }

    var isLoadingOptions: Bool = false
    var layoutCorrectionHint: LayoutCorrectionHint?
    /// The text the list ranks: the field's, or its layout correction when one shows.
    var rankedText: String {
        layoutCorrectionHint?.correctedQuery ?? query
    }

    var parameterQuery: String = "" {
        didSet {
            parameterQuerySubject.send(parameterQuery)
            if parameterQuery != oldValue { onParameterQueryEdit?() }
        }
    }

    /// Fired on every change to the parameter field's text, ahead of the debounced
    /// filter: a live preview holds off while the highlight follows the typing.
    @ObservationIgnored var onParameterQueryEdit: (@MainActor () -> Void)?

    // MARK: - Action cache (not tracked by @Observable for perf)

    @ObservationIgnored var actionCache: [ActionID: any Action] = [:]

    // MARK: - Activation animation triggers

    /// Per-row activation counter. Each row reads its own counter; bumping the value
    /// retriggers the row's keyframe pulse animation.
    var activationCounters: [ActionID: Int] = [:]

    func bumpActivation(for id: ActionID) {
        activationCounters[id, default: 0] += 1
    }

    /// The same for parameter options, keyed by option ID.
    var optionActivationCounters: [String: Int] = [:]

    func bumpActivation(forOption id: String) {
        optionActivationCounters[id, default: 0] += 1
    }

    // MARK: - Publishers

    private let querySubject = PassthroughSubject<String, Never>()
    private let parameterQuerySubject = PassthroughSubject<String, Never>()

    /// No `removeDuplicates()`: its memory outlives a panel session and misses the
    /// runs that don't come from here (the initial load), so it could drop the field's
    /// text as a "repeat" while the list showed another text's results.
    /// `PickerCoordinator` skips repeats of what it last ranked instead.
    var debouncedQuery: AnyPublisher<String, Never> {
        querySubject
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    var debouncedParameterQuery: AnyPublisher<String, Never> {
        parameterQuerySubject
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Reset

    func reset() {
        query = ""
        parameterQuery = ""
        actions = []
        selectedActionID = nil
        listResetToken = 0
        selectionRevealToken = 0
        listQuery = nil
        isLoading = false
        mode = .search
        modeStack = []
        activeAction = nil
        collectedValues = [:]
        collectedLabels = [:]
        currentParameter = nil
        parameterOptions = []
        selectedParameterOptionID = nil
        isLoadingOptions = false
        layoutCorrectionHint = nil
        actionCache = [:]
        activationCounters = [:]
        optionActivationCounters = [:]
    }

    /// Readies the picker for another run after one that kept it open (Shift held):
    /// clears what was typed and, in a parameter step, un-confirms that step's value
    /// so the next Return picks a new one. The mode and earlier steps' values stay
    /// as they were.
    func prepareForAnotherRun() {
        switch mode {
        case .search, .pushedActions:
            query = ""
        case .parameterInput:
            if let currentParameter {
                collectedValues[currentParameter.id] = nil
            }
            parameterQuery = ""
        }
    }

    // MARK: - Selection navigation

    func selectNext() {
        switch mode {
        case .search, .pushedActions:
            selectNextAction()
        case .parameterInput:
            selectNextParameterOption()
        }
    }

    func selectPrevious() {
        switch mode {
        case .search, .pushedActions:
            selectPreviousAction()
        case .parameterInput:
            selectPreviousParameterOption()
        }
    }

    // MARK: - Action list updates (with selection stability)

    /// Replaces the action list. `query` is the search text the rows were ranked for
    /// (nil for rows that aren't a ranking of the field).
    ///
    /// A list ranked for the same text as the one on screen is a refresh: a module
    /// reported new actions, or the picker came back with its state. Refreshes re-rank
    /// (the catalog fan-out answers in a different order each time, scores move with
    /// the clock), so the highlighted row stays highlighted wherever it lands, matched
    /// by ID; if it's gone, the row now in its place takes over. Anything else (new
    /// text, the first ranking after the cached list, pushed rows) starts on the first row.
    func updateActions(
        _ newActions: [ActionItem],
        cache: [ActionID: any Action] = [:],
        rankedFor query: String? = nil
    ) {
        let isRefresh = query != nil && query == listQuery
        let selectedIndex = selectedActionID.flatMap { id in actions.firstIndex { $0.id == id } }
        actions = newActions
        actionCache = cache
        listQuery = query
        guard isRefresh, let selectedIndex, !newActions.isEmpty else {
            selectedActionID = newActions.first?.id
            listResetToken &+= 1
            return
        }
        if let newIndex = newActions.firstIndex(where: { $0.id == selectedActionID }) {
            if newIndex != selectedIndex { selectionRevealToken &+= 1 }
        } else {
            selectedActionID = newActions[min(selectedIndex, newActions.count - 1)].id
        }
    }

    // MARK: - Parameter flow

    /// Starts collecting `action`'s parameters. `asRoot` puts the first step up with
    /// nothing beneath it, for an action that wasn't picked from a list (a keybinding's).
    func enterParameterMode(action: any Action, asRoot: Bool = false) {
        activeAction = action
        collectedValues = [:]
        collectedLabels = [:]
        // Pre-fill defaults
        for param in action.parameters {
            if let defaultValue = param.defaultValue {
                collectedValues[param.id] = defaultValue
            }
        }
        advanceToNextParameter(startingFrom: 0, asRoot: asRoot)
    }

    /// Moves to the first required parameter from `index` on that has no value yet. It
    /// takes the place of the action's step on screen, so Escape goes back to where the
    /// action was picked rather than through the values already given.
    func advanceToNextParameter(startingFrom index: Int, asRoot: Bool = false) {
        guard let action = activeAction else { return }
        let params = action.parameters
        for paramIndex in index ..< params.count {
            let param = params[paramIndex]
            if param.isRequired, collectedValues[param.id] == nil {
                currentParameter = param
                parameterQuery = ""
                parameterOptions = []
                selectedParameterOptionID = nil
                isLoadingOptions = false
                let step = PickerMode.parameterInput(actionID: action.id, parameterIndex: paramIndex)
                if asRoot {
                    showAsRoot(step)
                } else if case let .parameterInput(actionID, _) = mode, actionID == action.id {
                    setMode(step)
                } else {
                    pushMode(step)
                }

                // Pre-populate static selection options
                if case let .selection(options) = param.type {
                    parameterOptions = options
                    selectedParameterOptionID = options.first?.id
                } else if case .toggle = param.type {
                    parameterOptions = [
                        ParameterOption(id: "true", label: "On", iconName: "checkmark.circle"),
                        ParameterOption(id: "false", label: "Off", iconName: "xmark.circle"),
                    ]
                    selectedParameterOptionID = "true"
                }
                // For dynamicSelection, the coordinator will fetch options
                return
            }
        }
        // All required parameters filled — signal ready for execution
        // The coordinator checks this and executes
    }

    func confirmParameterValue(_ value: String, forParameterID parameterID: String) {
        collectedValues[parameterID] = value
        // Capture the label now: dynamic options are replaced once the next parameter loads.
        collectedLabels[parameterID] = parameterOptions.first { $0.id == value }?.label ?? value
    }

    /// Labels of the confirmed values in parameter order, for the search-field pill
    /// (Search Wallpapers › Wallhaven).
    var confirmedValueLabels: [String] {
        guard let action = activeAction else { return [] }
        return action.parameters.compactMap { collectedLabels[$0.id] }.filter { !$0.isEmpty }
    }

    var allRequiredParametersFilled: Bool {
        guard let action = activeAction else { return false }
        return action.parameters
            .filter(\.isRequired)
            .allSatisfy { collectedValues[$0.id] != nil }
    }

    var nextUnfilledParameterIndex: Int? {
        guard let action = activeAction else { return nil }
        return action.parameters.firstIndex { $0.isRequired && collectedValues[$0.id] == nil }
    }

    // MARK: - Page navigation

    private let pageSize = 10

    func selectNextPage() {
        switch mode {
        case .search, .pushedActions:
            selectActionByOffset(pageSize)
        case .parameterInput:
            selectParameterOptionByOffset(pageSize)
        }
    }

    func selectPreviousPage() {
        switch mode {
        case .search, .pushedActions:
            selectActionByOffset(-pageSize)
        case .parameterInput:
            selectParameterOptionByOffset(-pageSize)
        }
    }

    private func selectActionByOffset(_ offset: Int) {
        guard !actions.isEmpty else { return }
        guard let currentID = selectedActionID,
              let idx = actions.firstIndex(where: { $0.id == currentID })
        else {
            selectedActionID = offset > 0 ? actions.first?.id : actions.last?.id
            return
        }
        let targetIndex = max(0, min(actions.count - 1, idx + offset))
        selectedActionID = actions[targetIndex].id
    }

    private func selectParameterOptionByOffset(_ offset: Int) {
        guard !parameterOptions.isEmpty else { return }
        guard let currentID = selectedParameterOptionID,
              let idx = parameterOptions.firstIndex(where: { $0.id == currentID })
        else {
            selectedParameterOptionID = offset > 0 ? parameterOptions.first?.id : parameterOptions.last?.id
            return
        }
        let targetIndex = max(0, min(parameterOptions.count - 1, idx + offset))
        selectedParameterOptionID = parameterOptions[targetIndex].id
    }

    // MARK: - Private selection helpers

    private func selectNextAction() {
        guard !actions.isEmpty else { return }
        guard let currentID = selectedActionID,
              let idx = actions.firstIndex(where: { $0.id == currentID })
        else {
            selectedActionID = actions.first?.id
            return
        }
        let next = actions.index(after: idx)
        selectedActionID = (next < actions.endIndex) ? actions[next].id : currentID
    }

    private func selectPreviousAction() {
        guard !actions.isEmpty else { return }
        guard let currentID = selectedActionID,
              let idx = actions.firstIndex(where: { $0.id == currentID })
        else {
            selectedActionID = actions.last?.id
            return
        }
        if idx > actions.startIndex {
            selectedActionID = actions[actions.index(before: idx)].id
        }
    }

    private func selectNextParameterOption() {
        guard !parameterOptions.isEmpty else { return }
        guard let currentID = selectedParameterOptionID,
              let idx = parameterOptions.firstIndex(where: { $0.id == currentID })
        else {
            selectedParameterOptionID = parameterOptions.first?.id
            return
        }
        let next = parameterOptions.index(after: idx)
        selectedParameterOptionID = (next < parameterOptions.endIndex)
            ? parameterOptions[next].id : currentID
    }

    private func selectPreviousParameterOption() {
        guard !parameterOptions.isEmpty else { return }
        guard let currentID = selectedParameterOptionID,
              let idx = parameterOptions.firstIndex(where: { $0.id == currentID })
        else {
            selectedParameterOptionID = parameterOptions.last?.id
            return
        }
        if idx > parameterOptions.startIndex {
            selectedParameterOptionID = parameterOptions[parameterOptions.index(before: idx)].id
        }
    }
}

// MARK: - Mode navigation

/// Outside the class body for its length limit; `modeStack` is private to this file.
///
/// Escape goes back one level, to where the user came from in this picker session, and
/// closes the picker at the root. A parameter step or a pushed list is a level over the
/// list it was reached from. One that came up on its own — a run's results after the run
/// closed the picker, the browser chooser, a keybinding's parameter step — is the root:
/// going "back" would only flash a list the user never saw before closing.
extension PickerState {
    /// Whether Escape goes back a level rather than closing the picker.
    var canGoBack: Bool {
        !modeStack.isEmpty
    }

    /// Pushes `newMode` over the level on screen. Popping it puts that level back as it is
    /// now — its rows, selection and query — whatever the new one shows meanwhile.
    func pushMode(_ newMode: PickerMode) {
        modeStack.append(CoveredLevel(
            mode: mode, actions: actions, cache: actionCache, selectedActionID: selectedActionID,
            listQuery: listQuery, query: query
        ))
        setMode(newMode)
        Log.picker.debug("Mode pushed: \(String(describing: newMode), privacy: .public)")
    }

    /// Puts `newMode` up with nothing beneath it, so Escape closes the picker rather than
    /// going back.
    func showAsRoot(_ newMode: PickerMode) {
        modeStack = []
        setMode(newMode)
        if !newMode.isParameterStep { clearParameterStep() }
    }

    /// Goes back one level. Returns `false`, changing nothing, at the root.
    func popMode() -> Bool {
        guard let previous = modeStack.popLast() else { return false }
        setMode(previous.mode)
        actions = previous.actions
        actionCache = previous.cache
        selectedActionID = previous.selectedActionID
        listQuery = previous.listQuery
        if query != previous.query {
            query = previous.query
        }
        if !previous.mode.isParameterStep { clearParameterStep() }
        return true
    }

    /// Changes the level on screen, leaving the ones beneath as they are.
    private func setMode(_ newMode: PickerMode) {
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = newMode
        }
    }

    /// Drops the step that was left. Its action and values stay until another action's
    /// steps start.
    private func clearParameterStep() {
        parameterQuery = ""
        parameterOptions = []
        selectedParameterOptionID = nil
        currentParameter = nil
        isLoadingOptions = false
    }
}

/// A level beneath the one on screen, as it was when something was pushed over it.
private struct CoveredLevel {
    let mode: PickerMode
    let actions: [ActionItem]
    let cache: [ActionID: any Action]
    let selectedActionID: ActionID?
    let listQuery: String?
    let query: String
}
