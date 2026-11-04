@testable import Vibeshed
import XCTest

private struct StubAction: Action {
    let id: ActionID
    let title: String
    var subtitle: String = ""
    var iconName: String?
    var relevanceScore: Double = 0.5
    var keywords: [String] = []
    var parameters: [ActionParameter] = []
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var isFallback = false
    var requiresWordPrefixMatch = false
    func run(with _: ParameterValues) async throws -> ActionResult {
        .dismiss
    }
}

final class ActionScorerTests: XCTestCase {
    private func scoring(_ query: String, now: Date = Date()) -> ScoringContext {
        ScoringContext(
            usageCounts: [:], lastUsedDates: [:], query: query,
            systemContext: nil, now: now
        )
    }

    func testEmptyQuerySortsByRelevanceDescending() {
        let actions: [any Action] = [
            StubAction(id: ActionID("m/low"), title: "Low", relevanceScore: 0.2),
            StubAction(id: ActionID("m/high"), title: "High", relevanceScore: 0.9),
            StubAction(id: ActionID("m/mid"), title: "Mid", relevanceScore: 0.5),
        ]
        let (items, cache) = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:], query: "", scoring: scoring("")
        )
        XCTAssertEqual(items.map(\.id.actionName), ["high", "mid", "low"])
        XCTAssertEqual(cache.count, 3)
    }

    func testNonMatchingActionsDroppedForNonEmptyQuery() {
        let actions: [any Action] = [
            StubAction(id: ActionID("m/settings"), title: "Settings"),
            StubAction(id: ActionID("m/zzz"), title: "Nothing"),
        ]
        let (items, _) = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:], query: "set", scoring: scoring("set")
        )
        XCTAssertEqual(items.map(\.id.actionName), ["settings"])
    }

    func testEnrichmentEnablesKeywordMatch() {
        let action = StubAction(id: ActionID("m/x"), title: "Open Mail")
        // "compose" matches only via the alias-provided keyword enrichment.
        let withoutEnrichment = ActionScorer.scoreAndRank(
            allActions: [action], enrichments: [:], query: "compose", scoring: scoring("compose")
        )
        XCTAssertTrue(withoutEnrichment.0.isEmpty)

        let withEnrichment = ActionScorer.scoreAndRank(
            allActions: [action], enrichments: [ActionID("m/x"): ["compose"]],
            query: "compose", scoring: scoring("compose")
        )
        XCTAssertEqual(withEnrichment.0.count, 1)
        XCTAssertTrue(withEnrichment.0[0].keywords.contains("compose"))
    }

    func testBrowserTabWinsOverBookmarkForSameURL() {
        let tab = BrowserAction(
            id: ActionID("browser/tab.1"), title: "GitHub", subtitle: "",
            relevanceScore: 0.8, tabURL: "https://github.com/"
        ) { _ in .dismiss }
        let bookmark = BookmarkAction(
            id: ActionID("bookmark/bm.1"), title: "GitHub", subtitle: "",
            relevanceScore: 0.6, url: "https://github.com"
        ) { _ in .dismiss }

        let (items, _) = ActionScorer.scoreAndRank(
            allActions: [bookmark, tab], enrichments: [:], query: "", scoring: scoring("")
        )
        // Dedup drops the lower-scored bookmark from the visible list; the higher-scored
        // tab wins. (The cache deliberately isn't pruned on dedup — only the 200-cap is —
        // so a stale cache entry for the dropped item is expected, matching prior behavior.)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, ActionID("browser/tab.1"))
    }

    func testResultsCappedAndCachePruned() {
        let actions: [any Action] = (0 ..< 250).map {
            StubAction(id: ActionID("m/a\($0)"), title: "Item \($0)", relevanceScore: 0.5)
        }
        let (items, cache) = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:], query: "", scoring: scoring("")
        )
        XCTAssertEqual(items.count, 200)
        XCTAssertEqual(cache.count, 200)
    }

    func testDeduplicationKeyDefaultsToNil() {
        let action = StubAction(id: ActionID("m/x"), title: "X")
        XCTAssertNil(action.deduplicationKey)
    }

    func testURLActionsExposeNormalizedDedupKey() {
        let tab = BrowserAction(
            id: ActionID("browser/t"), title: "T", subtitle: "",
            tabURL: "https://Example.com/Path/"
        ) { _ in .dismiss }
        let bookmark = BookmarkAction(
            id: ActionID("bookmark/b"), title: "B", subtitle: "",
            url: "https://example.com/path"
        ) { _ in .dismiss }
        // Both normalize to the same key, which is what drives cross-source dedup.
        XCTAssertEqual(tab.deduplicationKey, "https://example.com/path")
        XCTAssertEqual(tab.deduplicationKey, bookmark.deduplicationKey)
    }

    func testActionsWithDistinctKeysAreNotDeduped() {
        let first = BrowserAction(
            id: ActionID("browser/a"), title: "A", subtitle: "",
            relevanceScore: 0.8, tabURL: "https://a.com"
        ) { _ in .dismiss }
        let second = BrowserAction(
            id: ActionID("browser/b"), title: "B", subtitle: "",
            relevanceScore: 0.7, tabURL: "https://b.com"
        ) { _ in .dismiss }
        let (items, _) = ActionScorer.scoreAndRank(
            allActions: [first, second], enrichments: [:], query: "", scoring: scoring("")
        )
        XCTAssertEqual(items.count, 2)
    }

    func testImminentEventOutranksAStrongerTextMatch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(3 * 60)
        // "standup" matches the exact title of the non-event action and only fuzzily
        // (s-t-a-n-d-u-p scattered) the event's — yet the event must still win.
        let exactMatch = StubAction(
            id: ActionID("m/standup"), title: "Standup", relevanceScore: 0.9
        )
        let event = StubAction(
            id: ActionID("calendar/event.x"), title: "Sprint Team Sync and Updates Prep",
            relevanceScore: 0.9,
            scheduledStart: start, scheduledEnd: start.addingTimeInterval(1800)
        )
        let (items, _) = ActionScorer.scoreAndRank(
            allActions: [exactMatch, event], enrichments: [:],
            query: "standup", scoring: scoring("standup", now: now)
        )
        XCTAssertEqual(items.map(\.id.actionName), ["event.x", "standup"])
    }

    func testDistantEventDoesNotOutrankAStrongerTextMatch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(8 * 3600)
        let exactMatch = StubAction(
            id: ActionID("m/standup"), title: "Standup", relevanceScore: 0.9
        )
        let event = StubAction(
            id: ActionID("calendar/event.x"), title: "Sprint Team Sync and Updates Prep",
            relevanceScore: 0.9,
            scheduledStart: start, scheduledEnd: start.addingTimeInterval(1800)
        )
        let (items, _) = ActionScorer.scoreAndRank(
            allActions: [exactMatch, event], enrichments: [:],
            query: "standup", scoring: scoring("standup", now: now)
        )
        XCTAssertEqual(items.map(\.id.actionName), ["standup", "event.x"])
    }

    func testEventsRankByHowSoonTheyStart() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ name: String, inMinutes: Double) -> StubAction {
            let start = now.addingTimeInterval(inMinutes * 60)
            return StubAction(
                id: ActionID("calendar/\(name)"), title: "Meeting \(name)",
                relevanceScore: 0.5,
                scheduledStart: start, scheduledEnd: start.addingTimeInterval(1800)
            )
        }
        let actions: [any Action] = [
            event("later", inMinutes: 90),
            event("soon", inMinutes: 2),
            event("mid", inMinutes: 30),
        ]
        let (items, _) = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:],
            query: "meeting", scoring: scoring("meeting", now: now)
        )
        XCTAssertEqual(items.map(\.id.actionName), ["soon", "mid", "later"])
    }

    func testFallbacksRankLastDespiteStrongerMatchAndUsage() {
        let now = Date()
        let actions: [any Action] = [
            StubAction(
                id: ActionID("websearch/search.google"), title: "Search Google for \u{201C}term\u{201D}",
                relevanceScore: 1, keywords: ["term"], isFallback: true
            ),
            StubAction(id: ActionID("m/weak"), title: "The Ruby Mangler", relevanceScore: 0),
            StubAction(id: ActionID("m/strong"), title: "Terminal", relevanceScore: 0.5),
        ]
        let heavyUse = ScoringContext(
            usageCounts: ["websearch/search.google": 500],
            lastUsedDates: ["websearch/search.google": now],
            query: "term", systemContext: nil, now: now
        )
        let (items, _) = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:], query: "term", scoring: heavyUse
        )
        XCTAssertEqual(items.map(\.id.actionName), ["strong", "weak", "search.google"])
    }

    func testResultCapKeepsFallbacks() {
        var actions: [any Action] = (0 ..< ActionScorer.maxResults + 50).map {
            StubAction(id: ActionID("m/a\($0)"), title: "Item \($0)")
        }
        actions.append(StubAction(
            id: ActionID("websearch/search.google"), title: "Search Google for item", isFallback: true
        ))
        let (items, cache) = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:], query: "item", scoring: scoring("item")
        )
        XCTAssertEqual(items.count, ActionScorer.maxResults)
        XCTAssertEqual(items.last?.id.rawValue, "websearch/search.google")
        XCTAssertEqual(cache.count, ActionScorer.maxResults)
    }

    func testNormalizeURL() {
        XCTAssertEqual(ActionScorer.normalizeURL("https://A.com/Path/"), "https://a.com/path")
        XCTAssertEqual(ActionScorer.normalizeURL("https://x.com/#frag"), "https://x.com")
        XCTAssertEqual(ActionScorer.normalizeURL("https://x.com///"), "https://x.com")
    }

    // MARK: - Word-prefix matching

    /// Apps and long pull request titles side by side: the fuzzy matcher alone would put
    /// the pull requests right under the app for most two- and three-letter queries.
    private var appsAndPullRequests: [any Action] {
        [
            StubAction(id: ActionID("application/safari"), title: "Safari", relevanceScore: 0.75),
            StubAction(id: ActionID("application/messages"), title: "Messages", relevanceScore: 0.75),
            StubAction(id: ActionID("application/finder"), title: "Finder", relevanceScore: 0.75),
            StubAction(
                id: ActionID("github/pr.1"), title: "Make the website satisfying",
                subtitle: "idmitriev/vibeshed #81", relevanceScore: 0.5, requiresWordPrefixMatch: true
            ),
            StubAction(
                id: ActionID("github/pr.2"), title: "fix: report Vibeshed's quit by launching apps through open",
                subtitle: "idmitriev/vibeshed #48", relevanceScore: 0.5, keywords: ["fix", "quit", "not", "reported"],
                requiresWordPrefixMatch: true
            ),
        ]
    }

    private func ranked(_ query: String) -> [String] {
        ActionScorer.scoreAndRank(
            allActions: appsAndPullRequests, enrichments: [:], query: query, scoring: scoring(query)
        ).0.map(\.id.rawValue)
    }

    func testWordPrefixActionsStayOutOfShortQueries() {
        let shortQueries = [("s", "safari"), ("sa", "safari"), ("saf", "safari"), ("mes", "messages"), ("fi", "finder")]
        for (query, app) in shortQueries {
            let ids = ranked(query)
            XCTAssertEqual(ids.first, "application/\(app)", query)
            XCTAssertFalse(ids.contains { $0.hasPrefix("github/") }, "\(query): \(ids)")
        }
        XCTAssertFalse(ranked("").contains { $0.hasPrefix("github/") }, "not in the empty-query list")
    }

    func testWordPrefixActionsMatchWholeWordStarts() {
        XCTAssertEqual(ranked("satis"), ["github/pr.1"])
        XCTAssertEqual(ranked("web sat"), ["github/pr.1"])
        XCTAssertEqual(ranked("#81"), ["github/pr.1"], "the number in the subtitle")
        XCTAssertEqual(Set(ranked("vibeshed")), ["github/pr.1", "github/pr.2"], "the repo in the subtitle")
        XCTAssertEqual(ranked("reported"), ["github/pr.2"], "a keyword word")
        XCTAssertEqual(ranked("ebsite"), [], "inside a word isn't a word start")
    }

    /// Words split between the title and the subtitle still match a word-prefix action,
    /// ranked below a match within one field; other actions still need the whole query
    /// in one field.
    func testWordPrefixWordsMayBeSpreadOverFields() {
        XCTAssertEqual(ranked("satis 81"), ["github/pr.1"])
        XCTAssertEqual(ranked("quit vibeshed"), ["github/pr.2"])
        XCTAssertEqual(ranked("satis 48"), [], "every word still has to start a word")

        let actions: [any Action] = [
            StubAction(id: ActionID("app/spread"), title: "Release notes", subtitle: "vibeshed"),
            StubAction(
                id: ActionID("history/spread"), title: "Release notes", subtitle: "vibeshed",
                requiresWordPrefixMatch: true
            ),
            StubAction(
                id: ActionID("history/whole"), title: "rel vibe, release notes", subtitle: "example",
                requiresWordPrefixMatch: true
            ),
        ]
        let ids = ActionScorer.scoreAndRank(
            allActions: actions, enrichments: [:], query: "rel vibe", scoring: scoring("rel vibe")
        ).0.map(\.id.rawValue)
        XCTAssertEqual(ids, ["history/whole", "history/spread"])
    }

    func testWordsSplitOnPunctuationWithoutRepeats() {
        XCTAssertEqual(
            WordPrefixMatch.words(in: ["Fix: fix the #66 font-switching", "feat/font"]),
            ["fix", "the", "66", "font", "switching", "feat"]
        )
        XCTAssertFalse(WordPrefixMatch.admits(queryLower: "  a ", words: ["abc"]))
        XCTAssertFalse(WordPrefixMatch.admits(queryLower: "---", words: ["abc"]))
        XCTAssertTrue(WordPrefixMatch.admits(queryLower: "ab c", words: ["abc", "cd"]))
    }
}
