@testable import Vibeshed
import XCTest

/// Short, obvious queries against `RankingCorpus`, with what earlier picks and the
/// calendar look like for each. `RANKING_DUMP=1 swift test --filter RankingTableTests`
/// prints each case's top rows with their scoring terms.
@MainActor
final class RankingTableTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testTable() async {
        var failures: [String] = []
        var dump: [String] = []
        for rankingCase in Self.cases {
            let ranked = await rank(rankingCase)
            let ids = ranked.map(\.id)
            if let problem = rankingCase.expectation.problem(in: ids) {
                failures.append("\(rankingCase.label): \(problem); got \(ids.prefix(4).joined(separator: ", "))")
            }
            dump.append(render(rankingCase, ranked))
        }
        if ProcessInfo.processInfo.environment["RANKING_DUMP"] != nil {
            print(dump.joined(separator: "\n"))
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }

    // MARK: - Cases

    private static let cases: [RankingCase] = [
        // "theme": all three titles hold "Theme" as a word; Switch Theme… has the highest relevance.
        RankingCase("theme", expect: .first("theme/switch")),
        RankingCase("theme", picks: [Pick("switch theme", "theme/switch", times: 10)], expect: .first("theme/switch")),
        RankingCase("theme", picks: [Pick("theme", "theme/switch", times: 10)], expect: .first("theme/switch")),
        // "mind": a whole word in the session title, m-i-n…d scattered in "Minimized".
        RankingCase("mind", expect: .first(RankingCorpus.mindSession)),
        RankingCase(
            "mind", picks: [Pick("restore", "window/restoreMinimized", times: 3)],
            expect: .first(RankingCorpus.mindSession)
        ),
        RankingCase(
            "mind", picks: [Pick("mind", "window/restoreMinimized", times: 2)],
            expect: .first("window/restoreMinimized")
        ),
        // "pr": an exact keyword of Search Pull Requests; P…r in "Pairing session".
        RankingCase("pr", expect: .first("github/searchPRs")),
        RankingCase("pr", pairingStartsIn: 3, expect: .first(RankingCorpus.pairingEvent)),
        // An event about to start outranks every text match, but a habit for this very
        // query beats one whose title only matches scattered (P…r) after a few picks.
        RankingCase(
            "pr", pairingStartsIn: 3, picks: [Pick("pr", "github/searchPRs", times: 5)],
            expect: .first("github/searchPRs")
        ),
        RankingCase(
            "pr", pairingStartsIn: 60, picks: [Pick("pr", "github/searchPRs", times: 2)],
            expect: .first("github/searchPRs")
        ),
        // "spot": the start of the app's name; a later word everywhere else.
        RankingCase("spot", expect: .first(RankingCorpus.spotifyApp)),
        RankingCase("spotify", expect: .first(RankingCorpus.spotifyApp)),
        // "left" and "grid": several titles hold the word; picks settle them.
        RankingCase("left", expect: .top(3, ["window/tileLeft", "tiling/moveLeft", "window/focusLeft"])),
        RankingCase("left", picks: [Pick("left", "window/tileLeft", times: 1)], expect: .first("window/tileLeft")),
        RankingCase(
            "grid", expect: .top(4, ["tiling/attach", "tiling/attachAll", "tiling/detach", "tiling/detachWindow"])
        ),
        RankingCase("grid", picks: [Pick("grid", "tiling/attachAll", times: 1)], expect: .first("tiling/attachAll")),
        // "restore": the start of one title, the last word of the other.
        RankingCase("restore", expect: .order(["window/restoreMinimized", "window/toggleMaximize"])),
        // The queries the demo fell back to, and exact titles.
        RankingCase("tile left", expect: .first("window/tileLeft")),
        RankingCase("attach all", expect: .first("tiling/attachAll")),
        RankingCase("switch theme", expect: .first("theme/switch")),
        RankingCase("my mind", expect: .first(RankingCorpus.mindSession)),
        RankingCase("pull", expect: .first("github/searchPRs")),
        RankingCase("lock", expect: .first("system/lock")),
        RankingCase("sleep", expect: .first("system/sleep")),
        RankingCase("dracula", expect: .first("theme/apply.dracula")),
        RankingCase("bluetooth", expect: .first("settings/bluetooth")),
        RankingCase("next theme", expect: .first("theme/next")),
        RankingCase("search spotify", expect: .first("spotify/search")),
        RankingCase("center window", expect: .first("window/center")),
        // A session waiting on the user tops the empty list, even over an action used a
        // minute ago, but not an event about to start.
        RankingCase(
            "", awaiting: RankingCorpus.lintSession, picks: [Pick("", "theme/switch", times: 50, minutesAgo: 1)],
            expect: .first(RankingCorpus.lintSession)
        ),
        RankingCase(
            "", pairingStartsIn: 3, awaiting: RankingCorpus.lintSession, expect: .first(RankingCorpus.pairingEvent)
        ),
        // "fix" starts the other session's title but only the waiting one's branch.
        RankingCase("fix", expect: .first("anthropic/session.release")),
        RankingCase("fix", awaiting: RankingCorpus.lintSession, expect: .first(RankingCorpus.lintSession)),
        RankingCase("waiting", awaiting: RankingCorpus.lintSession, expect: .first(RankingCorpus.lintSession)),
        // Too short to name the session, so its scattered S…a in the subtitle gets no lift.
        RankingCase("sa", awaiting: RankingCorpus.lintSession, expect: .first("application/app.com.apple.Safari")),
    ]

    // MARK: - Ranking

    private func rank(_ rankingCase: RankingCase) async -> [Ranked] {
        let corpus = await RankingCorpus.build(
            now: Self.now, pairingStartsIn: rankingCase.pairingStartsIn, awaiting: rankingCase.awaiting
        ) + RankingCorpus.fallbacks(for: rankingCase.query)
        let scoring = scoring(rankingCase)
        let query = FuzzyMatcher.Query(scoring.query)
        var ranked: [Ranked] = corpus.compactMap { scorable in
            ActionScorer.evaluate(scorable, query: query, scoring: scoring).map { Ranked(scorable: scorable, eval: $0) }
        }
        // Stable: equal scores keep corpus order, as `scoreAndRank`'s sort does in practice.
        ranked = ranked.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.scorable.isFallback, lhs.element.eval.final)
            let right = (rhs.element.scorable.isFallback, rhs.element.eval.final)
            if ActionScorer.ranksBefore(left, right) { return true }
            if ActionScorer.ranksBefore(right, left) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return ranked
    }

    /// Picks go through the usage tracker as the picker records them, ten minutes ago
    /// unless a pick says otherwise.
    private func scoring(_ rankingCase: RankingCase) -> ScoringContext {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("ranking-\(UUID().uuidString).json")
        let tracker = UsageTracker(storageURL: storage)
        for pick in rankingCase.picks {
            for _ in 0 ..< pick.times {
                tracker.recordUsage(
                    actionID: ActionID(pick.actionID), query: pick.query,
                    at: Self.now.addingTimeInterval(-pick.minutesAgo * 60)
                )
            }
        }
        var scoring = tracker.makeScoringContext(query: rankingCase.query)
        scoring.now = Self.now
        scoring.queryAffinity = tracker.queryHistory.shares(for: rankingCase.query, now: Self.now)
        return scoring
    }

    private func render(_ rankingCase: RankingCase, _ ranked: [Ranked]) -> String {
        var lines = ["== \(rankingCase.label)  [\(rankingCase.expectation)]"]
        for (index, row) in ranked.prefix(5).enumerated() {
            let eval = row.eval
            let terms = [eval.final, eval.fuzzy, eval.affinity, eval.imminence, eval.awaiting]
                .map { String(format: "%.3f", $0) }
            lines.append("  \(index + 1). \(terms.joined(separator: " "))  \(row.id)  \(row.scorable.action.title)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Table types

private struct Ranked {
    let scorable: ScorableAction
    let eval: ActionScorer.Evaluation
    var id: String {
        scorable.action.id.rawValue
    }
}

/// `times` runs of `actionID` from the picker after typing `query`.
private struct Pick {
    let query: String
    let actionID: String
    let times: Int
    let minutesAgo: Double

    init(_ query: String, _ actionID: String, times: Int, minutesAgo: Double = 10) {
        self.query = query
        self.actionID = actionID
        self.times = times
        self.minutesAgo = minutesAgo
    }
}

private struct RankingCase {
    let query: String
    let pairingStartsIn: Double?
    let awaiting: String?
    let picks: [Pick]
    let expectation: Expectation

    init(
        _ query: String, pairingStartsIn: Double? = nil, awaiting: String? = nil, picks: [Pick] = [],
        expect: Expectation
    ) {
        self.query = query
        self.pairingStartsIn = pairingStartsIn
        self.awaiting = awaiting
        self.picks = picks
        self.expectation = expect
    }

    var label: String {
        var parts = ["\"\(query)\""]
        if let pairingStartsIn { parts.append("event in \(Int(pairingStartsIn)) min") }
        if let awaiting { parts.append("\(awaiting) waiting") }
        for pick in picks {
            parts.append("\(pick.actionID) ×\(pick.times) via \"\(pick.query)\"")
        }
        return parts.joined(separator: ", ")
    }
}

private enum Expectation: CustomStringConvertible {
    case first(String)
    /// These IDs, in any order, fill the top `count` rows.
    case top(Int, Set<String>)
    /// These IDs lead the list in this order.
    case order([String])

    func problem(in ids: [String]) -> String? {
        switch self {
        case let .first(id):
            return ids.first == id ? nil : "expected \(id) first"
        case let .top(count, expected):
            return Set(ids.prefix(count)) == expected ? nil : "expected \(expected.sorted()) on top"
        case let .order(expected):
            return Array(ids.prefix(expected.count)) == expected ? nil : "expected \(expected) in order"
        }
    }

    var description: String {
        switch self {
        case let .first(id): "first: \(id)"
        case let .top(count, ids): "top \(count): \(ids.sorted().joined(separator: ", "))"
        case let .order(ids): "order: \(ids.joined(separator: " > "))"
        }
    }
}
