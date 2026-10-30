import Foundation

/// Debug-only: writes the most recent query's full ranking, with a per-row
/// breakdown of every scoring term, to `~/.config/vibeshed/last-actions.txt`.
/// Used to diagnose relevance ("why is X above Y for this query?", "where did Z go?").
///
/// Re-ranks the whole scored corpus uncapped via `ActionScorer.evaluate` — the same
/// math the picker uses — so it also lists what fell below the display cap and what
/// was collapsed as a duplicate. `fuzzy + affin + ctx + immin + await` equals `final`.
enum ActionListDebugDump {
    /// Writes the dump in the background. No-op outside DEBUG builds.
    static func schedule(query: String, displayed: [ActionItem], corpus: [ScorableAction], scoring: ScoringContext) {
        #if DEBUG
        // Unit tests drive the query pipeline too; keep them out of the user's config dir.
        guard NSClassFromString("XCTestCase") == nil else { return }
        let correctedQuery = scoring.query == query ? nil : scoring.query
        Task.detached(priority: .utility) {
            write(query: query, correctedQuery: correctedQuery, displayed: displayed, corpus: corpus, scoring: scoring)
        }
        #endif
    }
}

#if DEBUG
extension ActionListDebugDump {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vibeshed/last-actions.txt")

    private typealias Entry = (scorable: ScorableAction, eval: ActionScorer.Evaluation)

    static func write(
        query: String,
        correctedQuery: String?,
        displayed: [ActionItem],
        corpus: [ScorableAction],
        scoring: ScoringContext
    ) {
        let text = render(
            query: query, correctedQuery: correctedQuery,
            displayed: displayed, corpus: corpus, scoring: scoring
        )
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.picker.error("Action list dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func render(
        query: String,
        correctedQuery: String?,
        displayed: [ActionItem],
        corpus: [ScorableAction],
        scoring: ScoringContext
    ) -> String {
        let typed = FuzzyMatcher.Query(scoring.query)
        var matched: [Entry] = corpus.compactMap { scorable in
            ActionScorer.evaluate(scorable, query: typed, scoring: scoring).map { (scorable, $0) }
        }
        matched.sort {
            ActionScorer.ranksBefore(
                ($0.scorable.isFallback, $0.eval.final), ($1.scorable.isFallback, $1.eval.final)
            )
        }

        // Mirror ActionScorer's dedup: the first (highest-scored) holder of a key wins.
        var keyOwners: [String: ActionID] = [:]
        var kept: [Entry] = []
        var duplicates: [(entry: Entry, winner: ActionID)] = []
        for entry in matched {
            guard let key = entry.scorable.action.deduplicationKey, !key.isEmpty else {
                kept.append(entry)
                continue
            }
            if let winner = keyOwners[key] {
                duplicates.append((entry, winner))
            } else {
                keyOwners[key] = entry.scorable.action.id
                kept.append(entry)
            }
        }

        let byID = Dictionary(matched.map { ($0.scorable.action.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shownIDs = Set(displayed.map(\.id))
        let belowCap = kept.filter { !shownIDs.contains($0.scorable.action.id) }

        var lines = header(query: query, correctedQuery: correctedQuery, scoring: scoring)
        lines.append(
            "corpus: \(corpus.count)  matched: \(matched.count)  shown: \(displayed.count)"
                + "  below cap (\(ActionScorer.maxResults)): \(belowCap.count)  duplicates: \(duplicates.count)"
                + "  no match: \(corpus.count - matched.count)"
        )

        lines += section("SHOWN", start: 1, entries: displayed.map { item in (byID[item.id], item.id, nil) }, scoring)
        lines += section(
            "BELOW DISPLAY CAP", start: displayed.count + 1,
            entries: belowCap.map { ($0, $0.scorable.action.id, nil) }, scoring
        )
        lines += section(
            "REMOVED AS DUPLICATE (same deduplicationKey as a higher-scored action)", start: 1,
            entries: duplicates.map { ($0.entry, $0.entry.scorable.action.id, "[dup of \($0.winner.rawValue)]") },
            scoring
        )
        return lines.joined(separator: "\n") + "\n"
    }

    private static func header(query: String, correctedQuery: String?, scoring: ScoringContext) -> [String] {
        var lines: [String] = []
        lines.append("time:    \(ISO8601DateFormatter().string(from: scoring.now))")
        lines.append("query:   \"\(query)\"")
        if let correctedQuery {
            lines.append("layout-corrected to: \"\(correctedQuery)\"")
        }
        if let ctx = scoring.systemContext {
            lines.append(
                "context: app=\(ctx.focusedAppBundleID ?? "-") hour=\(ctx.hour) weekend=\(ctx.isWeekend)"
                    + " muted=\(ctx.isOutputMuted) spotify=\(ctx.isSpotifyRunning) windows=\(ctx.visibleWindowCount)"
            )
        }
        typealias Weight = FuzzyMatcher.Weight
        lines.append(
            "fuzzy = title*\(Weight.title) + subtitle*\(Weight.subtitle)"
                + " + keyword(\(Weight.exactKeyword) exact, \(Weight.keywordPrefix) prefix)"
                + " + relevance*\(Weight.relevance) + usage*\(Weight.usage)"
                + "  (empty query: relevance*\(Weight.emptyQueryRelevance) + usage*\(Weight.emptyQueryUsage))"
        )
        lines.append("usage = recency*0.6 + frequency*0.4")
        lines.append("affin = \(ActionScorer.affinityWeight) * share of the picks made after typing this query")
        lines.append(
            "await = \(ActionScorer.awaitingUserBoost) when waiting on the user, if nothing or its words are typed"
        )
        return lines
    }

    private static func section(
        _ title: String,
        start: Int,
        entries: [(entry: Entry?, id: ActionID, note: String?)],
        _ scoring: ScoringContext
    ) -> [String] {
        guard !entries.isEmpty else { return [] }
        var lines = ["", "== \(title) =="]
        lines.append([
            pad("#", 4), pad("final", 7), pad("fuzzy", 7), pad("relev", 6), pad("usage", 6),
            pad("uses", 5), pad("affin", 6), pad("ctx", 6), pad("immin", 6), pad("await", 6), pad("action id", 44),
            "title — subtitle",
        ].joined(separator: " "))
        for (offset, row) in entries.enumerated() {
            var line = self.row(rank: start + offset, entry: row.entry, id: row.id, scoring: scoring)
            if let note = row.note { line += "  \(note)" }
            lines.append(line)
        }
        return lines
    }

    private static func row(rank: Int, entry: Entry?, id: ActionID, scoring: ScoringContext) -> String {
        let uses = scoring.usageCounts[id.rawValue] ?? 0
        guard let (scorable, eval) = entry else {
            return [pad("\(rank)", 4), "(not found in scored corpus)", id.rawValue].joined(separator: " ")
        }
        let action = scorable.action
        let label = action.subtitle.isEmpty ? action.title : "\(action.title) — \(action.subtitle)"
        return [
            pad("\(rank)", 4), pad(num(eval.final), 7), pad(num(eval.fuzzy), 7),
            pad(num(scorable.target.relevanceScore), 6), pad(num(eval.usage), 6), pad("\(uses)", 5),
            pad(num(eval.affinity), 6), pad(num(eval.context), 6), pad(num(eval.imminence), 6),
            pad(num(eval.awaiting), 6), pad(id.rawValue, 44), label,
        ].joined(separator: " ")
    }

    private static func num(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }
}
#endif
