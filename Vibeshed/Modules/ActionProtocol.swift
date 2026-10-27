import SwiftUI

// MARK: - ActionID

struct ActionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(module: String, name: String) {
        self.rawValue = "\(module)/\(name)"
    }

    var description: String {
        rawValue
    }

    var moduleID: String {
        if let idx = rawValue.firstIndex(of: "/") {
            return String(rawValue[..<idx])
        }
        return rawValue
    }

    /// The action name part after the module separator (e.g. "cycleLeft" from "window/cycleLeft").
    var actionName: String {
        if let idx = rawValue.firstIndex(of: "/") {
            return String(rawValue[rawValue.index(after: idx)...])
        }
        return rawValue
    }
}

// MARK: - Action Protocol

protocol Action: Sendable, Identifiable where ID == ActionID {
    var id: ActionID { get }
    var title: String { get }
    var subtitle: String { get }
    var iconName: String? { get }
    /// Filesystem path to an app bundle whose Finder icon represents this action
    /// (e.g. an app or a window belonging to an app). When non-nil, the picker
    /// renders the real app icon in preference to `iconName`.
    var appIconPath: String? { get }
    var relevanceScore: Double { get }
    var keywords: [String] { get }
    var parameters: [ActionParameter] { get }

    func run(with values: ParameterValues) async throws -> ActionResult

    /// When true, the picker activates this action on a single mouse click.
    /// Default is false (double-click required) to avoid accidental activation.
    var activatesOnSingleClick: Bool { get }

    /// Cross-source dedup key. Actions returning the same non-nil key are collapsed
    /// to one in the ranked list, keeping the highest-scored (e.g. a live browser tab
    /// and a history entry for the same URL). Default `nil` opts out of dedup.
    var deduplicationKey: String? { get }

    /// Wall-clock start of the thing this action represents, when it has one
    /// (a calendar event, a meeting to join). Actions that report it are ranked
    /// to the top of the list as their start approaches — see `ImminenceScorer`.
    /// Default `nil` opts out; so should anything without a real clock time
    /// (all-day events, recurring templates).
    var scheduledStart: Date? { get }

    /// Wall-clock end paired with `scheduledStart`, used to tell an event that is
    /// under way from one that has already finished. Default `nil`.
    var scheduledEnd: Date? { get }

    /// Catch-all actions (e.g. "Search Google for …") that match nearly any query.
    /// They always rank below every non-fallback result regardless of score, usage
    /// or context boosts, and survive the result cap. Default `false`.
    var isFallback: Bool { get }

    /// Matches only a query of 3+ characters whose every word starts a word of the
    /// title, subtitle or keywords (see `WordPrefixMatch`), so long titles that fuzzy-match
    /// almost any short query (prefetched pull requests) stay out of the way of apps.
    /// Default `false`.
    var requiresWordPrefixMatch: Bool { get }

    /// Types into the app the user was in — paste on select posts ⌘V. That needs the
    /// keyboard focus the picker holds, so a Shift run of such an action closes the
    /// picker like a plain run instead of keeping it open. Default `false`.
    var typesIntoFrontmostApp: Bool { get }

    /// The thing this action opens is blocked until the user answers it, such as an
    /// agent session sitting on a permission prompt or a question. Ranked above
    /// comparable matches; see `ActionScorer.awaitingUserBoost`. Default `false`.
    var isAwaitingUser: Bool { get }

    @MainActor
    func makeListItemView() -> AnyView?
    @MainActor
    func makePreviewView() -> AnyView?
}

extension Action {
    var iconName: String? {
        nil
    }

    var appIconPath: String? {
        nil
    }

    var keywords: [String] {
        []
    }

    var parameters: [ActionParameter] {
        []
    }

    var activatesOnSingleClick: Bool {
        false
    }

    var deduplicationKey: String? {
        nil
    }

    var scheduledStart: Date? {
        nil
    }

    var scheduledEnd: Date? {
        nil
    }

    var isFallback: Bool {
        false
    }

    var requiresWordPrefixMatch: Bool {
        false
    }

    var typesIntoFrontmostApp: Bool {
        false
    }

    var isAwaitingUser: Bool {
        false
    }

    @MainActor
    func makeListItemView() -> AnyView? {
        nil
    }

    @MainActor
    func makePreviewView() -> AnyView? {
        nil
    }
}
