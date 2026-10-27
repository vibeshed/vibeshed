import Foundation

/// An action bundled with the precomputed lowercase forms the fuzzy matcher needs.
/// Built once when the catalog corpus is (re)fetched, so per-keystroke scoring does
/// no string lowercasing or `Array(String)` conversion at all.
struct ScorableAction: Sendable {
    let action: any Action
    /// Keywords including any alias enrichments, in original casing (shown in UI).
    let keywords: [String]
    let target: FuzzyMatcher.ScoreTarget
    /// Scheduled window, hoisted out of the action so the per-keystroke imminence
    /// boost needs no witness-table lookups.
    let scheduledStart: Date?
    let scheduledEnd: Date?
    let isFallback: Bool
    /// The words a query must start, for actions that require a word-prefix match; nil
    /// for every other action.
    let prefixWords: [String]?
    /// The words a typed query must start for the waiting-on-user boost, for actions
    /// that are `isAwaitingUser`; nil for every other action.
    let awaitingUserWords: [String]?

    init(action: any Action, extraKeywords: [String] = []) {
        self.action = action
        let combined = action.keywords + extraKeywords
        self.keywords = combined
        self.scheduledStart = action.scheduledStart
        self.scheduledEnd = action.scheduledEnd
        self.isFallback = action.isFallback
        self.prefixWords = action.requiresWordPrefixMatch
            ? WordPrefixMatch.words(in: [action.title, action.subtitle] + combined)
            : nil
        self.awaitingUserWords = action.isAwaitingUser
            ? WordPrefixMatch.words(in: [action.title, action.subtitle] + combined)
            : nil
        self.target = FuzzyMatcher.ScoreTarget(
            title: action.title,
            subtitle: action.subtitle,
            keywords: combined,
            relevanceScore: action.relevanceScore
        )
    }
}

/// Pure, actor-independent scoring/ranking of actions into display items.
///
/// This is the per-keystroke hot path (fuzzy scoring + sort + URL dedup over the full
/// combined action set). It takes only `Sendable` inputs and returns `Sendable` output
/// so `PickerCoordinator` can run it off the main actor via `Task.detached`, keeping
/// scoring off the main thread during typing.
enum ActionScorer {
    /// Maximum rendered results — nobody scrolls past 200 in a launcher.
    static let maxResults = 200

    typealias RankKey = (isFallback: Bool, score: Double)

    /// Weight of an action's share of the picks made for what's typed
    /// (`ScoringContext.queryAffinity`). Enough for a habit to lift its action over
    /// any closer text match — a single pick adds half of it — while an event about
    /// to start (`ImminenceScorer`) still comes first.
    static let affinityWeight = 0.5

    /// Lift for an action blocked on the user (`Action.isAwaitingUser`), given with
    /// nothing typed or when every typed word starts one of its words. It tops the rest
    /// of the empty list and any comparable match, while an event about to start
    /// (`ImminenceScorer.maxBoost`) still comes first. A short or scattered match gets
    /// none, so a waiting session doesn't take over queries meant for something else.
    static let awaitingUserBoost = 0.75

    /// One action's score, split into its terms. `final` is what ranking sorts by.
    struct Evaluation {
        /// Fuzzy match incl. weighted relevance and usage (see `FuzzyMatcher.score`).
        let fuzzy: Double
        /// Raw usage boost fed into `fuzzy`.
        let usage: Double
        /// Weighted share of the picks made for this query.
        let affinity: Double
        let context: Double
        let imminence: Double
        let awaiting: Double
        let titleRanges: [Range<String.Index>]

        var final: Double { fuzzy + affinity + context + imminence + awaiting }
    }

    /// Scores one action; nil when it doesn't match the query at all.
    static func evaluate(
        _ scorable: ScorableAction,
        query: FuzzyMatcher.Query,
        scoring: ScoringContext
    ) -> Evaluation? {
        if let words = scorable.prefixWords, !WordPrefixMatch.admits(queryLower: query.lowered, words: words) {
            return nil
        }
        let action = scorable.action
        let usageBoost = scoring.usageBoost(for: action.id)
        guard let result = FuzzyMatcher.score(
            query,
            target: scorable.target,
            usageBoost: usageBoost
        ) else { return nil }

        let contextBoost: Double = if let ctx = scoring.systemContext {
            ContextualScorer.boost(
                actionID: action.id, moduleID: action.id.moduleID, context: ctx
            )
        } else {
            0
        }
        // Deliberately unclamped and applied on top: an event about to start
        // outranks even an exact match elsewhere in the list.
        let imminenceBoost = ImminenceScorer.boost(
            scheduledStart: scorable.scheduledStart,
            scheduledEnd: scorable.scheduledEnd,
            now: scoring.now
        )
        return Evaluation(
            fuzzy: result.score,
            usage: usageBoost,
            affinity: affinityWeight * (scoring.queryAffinity[action.id.rawValue] ?? 0),
            context: contextBoost,
            imminence: imminenceBoost,
            awaiting: awaitingBoost(scorable, query: query),
            titleRanges: result.titleRanges
        )
    }

    /// `awaitingUserBoost` for an action waiting on the user, when the query names it.
    static func awaitingBoost(_ scorable: ScorableAction, query: FuzzyMatcher.Query) -> Double {
        guard let words = scorable.awaitingUserWords else { return 0 }
        guard query.isEmpty || WordPrefixMatch.admits(queryLower: query.lowered, words: words) else { return 0 }
        return awaitingUserBoost
    }

    /// Scores the precomputed corpus against `query`, ranks it, dedups browser tabs vs
    /// bookmark/history entries by URL, and caps the result.
    static func scoreAndRank(
        corpus: [ScorableAction],
        query: String,
        scoring: ScoringContext
    ) -> ([ActionItem], [ActionID: any Action]) {
        let query = FuzzyMatcher.Query(query)

        var scored: [(item: ActionItem, action: any Action, score: Double, isFallback: Bool)] = []
        var cache: [ActionID: any Action] = [:]

        for scorable in corpus {
            guard let eval = evaluate(scorable, query: query, scoring: scoring) else { continue }
            let action = scorable.action
            let finalScore = eval.final
            let item = ActionItem(
                id: action.id,
                title: action.title,
                subtitle: action.subtitle,
                iconSystemName: action.iconName,
                appIconPath: action.appIconPath,
                score: finalScore,
                moduleID: action.id.moduleID,
                hasParameters: !action.parameters.filter(\.isRequired).isEmpty,
                keywords: scorable.keywords,
                titleHighlightRanges: eval.titleRanges.isEmpty ? nil : eval.titleRanges
            )
            scored.append((item: item, action: action, score: finalScore, isFallback: scorable.isFallback))
            cache[action.id] = action
        }

        scored.sort { ranksBefore(($0.isFallback, $0.score), ($1.isFallback, $1.score)) }

        // Collapse actions sharing a deduplication key (e.g. a browser tab and a
        // bookmark/history entry for the same URL). Higher-scored entries are kept
        // because they sort first, so the survivor is the better-ranked one.
        var seenKeys: Set<String> = []
        scored.removeAll { entry in
            guard let key = entry.action.deduplicationKey, !key.isEmpty else { return false }
            return !seenKeys.insert(key).inserted
        }

        if scored.count > maxResults {
            // Trim from the ranked (non-fallback) section so fallbacks, which sort
            // last, stay reachable at the end of the list.
            let fallbackCount = scored.reversed().prefix { $0.isFallback }.count
            let keepRanked = max(0, maxResults - fallbackCount)
            let droppedRange = keepRanked ..< (scored.count - fallbackCount)
            for entry in scored[droppedRange] {
                cache.removeValue(forKey: entry.action.id)
            }
            scored.removeSubrange(droppedRange)
        }

        return (scored.map(\.item), cache)
    }

    /// Ranking order: non-fallback actions before fallbacks, then higher score first.
    static func ranksBefore(_ lhs: RankKey, _ rhs: RankKey) -> Bool {
        if lhs.isFallback != rhs.isFallback { return rhs.isFallback }
        return lhs.score > rhs.score
    }

    /// Convenience over the corpus variant for callers holding raw actions —
    /// builds the precomputed forms inline. Equivalent output.
    static func scoreAndRank(
        allActions: [any Action],
        enrichments: [ActionID: [String]],
        query: String,
        scoring: ScoringContext
    ) -> ([ActionItem], [ActionID: any Action]) {
        let corpus = allActions.map {
            ScorableAction(action: $0, extraKeywords: enrichments[$0.id] ?? [])
        }
        return scoreAndRank(corpus: corpus, query: query, scoring: scoring)
    }

    static func normalizeURL(_ url: String) -> String {
        var normalized = url.lowercased()
        if let fragment = normalized.firstIndex(of: "#") { normalized = String(normalized[..<fragment]) }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

/// The stricter match for actions with `requiresWordPrefixMatch`: the query needs
/// `minimumQueryLength` characters, and each of its words must start one of the action's
/// words. "satis" and "web sat" find "Make the website satisfying"; "sa" and "mes" don't,
/// though the fuzzy matcher alone would take both.
enum WordPrefixMatch {
    static let minimumQueryLength = 3

    /// Lowercased letter-and-digit runs, without repeats: "feat/font-switching" gives
    /// "feat", "font", "switching"; "#66" gives "66".
    static func words(in strings: [String]) -> [String] {
        var seen: Set<String> = []
        return strings.flatMap { string in
            string.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        }
        .filter { seen.insert($0).inserted }
    }

    static func admits(queryLower: String, words: [String]) -> Bool {
        guard queryLower.trimmingCharacters(in: .whitespaces).count >= minimumQueryLength else { return false }
        let queryWords = Self.words(in: [queryLower])
        guard !queryWords.isEmpty else { return false }
        return queryWords.allSatisfy { queryWord in
            words.contains { $0.hasPrefix(queryWord) }
        }
    }
}
