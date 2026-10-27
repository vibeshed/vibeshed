import Foundation
@testable import Vibeshed

/// The catalog `RankingTableTests` ranks against. Modules that build their actions
/// without touching the machine contribute their real actions (window, tiling, theme,
/// settings, system, GitHub, web search), so the table follows their titles, keywords
/// and relevance as they change. Modules whose rows come from the machine — installed
/// apps, Spotify, the calendar, Claude sessions — are mirrored from the builders named
/// on each row.
enum RankingCorpus {
    static let spotifyApp = "application/app.com.spotify.client"
    static let mindSession = "anthropic/session.mind"
    static let lintSession = "anthropic/session.lint"
    static let pairingEvent = "calendar/event.pairing"

    /// `pairingStartsIn` places the "Pairing session" event that many minutes after
    /// `now`; nil leaves it out of the calendar. `awaiting` names the Claude session
    /// that is waiting on the user, if any.
    static func build(now: Date, pairingStartsIn: Double?, awaiting: String? = nil) async -> [ScorableAction] {
        let scoring = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: "", systemContext: nil)
        let theme = ThemeModule()
        await theme.configDidUpdate(ThemeConfig())
        // Built-in themes only: user themes and installed fonts differ from Mac to Mac.
        let themeActions = await theme.provideActions(query: "", scoring: scoring).filter {
            guard let action = $0 as? ThemeAction else { return false }
            return action.font == nil && (action.theme?.source ?? .builtIn) == .builtIn
        }
        var actions: [any Action] = themeActions
        actions += await WindowModule().provideActions(query: "", scoring: scoring)
        actions += await TilingModule().provideActions(query: "", scoring: scoring)
        actions += await SettingsModule().provideActions(query: "", scoring: scoring)
        actions += await SystemModule().provideActions(query: "", scoring: scoring)
        actions += await GitHubModule().provideActions(query: "", scoring: scoring)
        actions += applications + spotify + claude(awaiting: awaiting)
        actions += calendar(now: now, pairingStartsIn: pairingStartsIn)
        return actions.map { ScorableAction(action: $0) }
    }

    /// The web search fallbacks the picker always adds for a typed query.
    static func fallbacks(for query: String) async -> [ScorableAction] {
        let scoring = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: query, systemContext: nil)
        return await WebSearchModule().provideActions(query: query, scoring: scoring).map { ScorableAction(action: $0) }
    }

    // MARK: - Mirrored rows

    /// `ApplicationModule.buildActions` and `buildAppAction`: running apps at 0.75,
    /// others at 0.6 with a "Launch" subtitle.
    private static var applications: [any Action] {
        let apps: [(id: String, name: String, running: Bool)] = [
            ("com.spotify.client", "Spotify", true),
            ("com.apple.Safari", "Safari", true),
            ("com.mitchellh.ghostty", "Ghostty", true),
            ("com.apple.finder", "Finder", true),
            ("dev.zed.Zed", "Zed", false),
            ("com.apple.systempreferences", "System Settings", false),
            ("com.apple.iCal", "Calendar", false),
            ("com.apple.Terminal", "Terminal", false),
            ("com.anthropic.claudefordesktop", "Claude", true),
        ]
        let perApp: [any Action] = apps.map { app in
            RankingRow(
                id: "application/app.\(app.id)", title: app.name,
                subtitle: app.running ? "Running · 1 window" : "Launch",
                relevanceScore: app.running ? 0.75 : 0.6,
                keywords: ["app", "application"] + (app.running ? [] : ["launch"]) + [app.name.lowercased()]
            )
        }
        return perApp + [
            RankingRow(
                id: "application/launchOrFocus", title: "Launch or Focus Application",
                subtitle: "Launch if not running, focus or cycle windows if running", relevanceScore: 0.9,
                keywords: ["launch", "focus", "open", "switch", "activate", "cycle", "app"], hasParameters: true
            ),
            RankingRow(
                id: "application/quit", title: "Quit Application", subtitle: "Quit a running application",
                relevanceScore: 0.7, keywords: ["quit", "close", "terminate", "kill", "application", "app", "exit"],
                hasParameters: true
            ),
        ]
    }

    /// `SpotifyModule+Actions.swift`, with search available (Open Spotify Search at 0.6).
    private static var spotify: [any Action] {
        [
            RankingRow(
                id: "spotify/playPause", title: "Play / Pause", subtitle: "Toggle Spotify playback",
                relevanceScore: 0.9, keywords: ["spotify", "play", "pause", "music", "media"]
            ),
            RankingRow(
                id: "spotify/next", title: "Next Track", subtitle: "Skip to next track in Spotify",
                relevanceScore: 0.85, keywords: ["spotify", "next", "skip", "forward", "track"]
            ),
            RankingRow(
                id: "spotify/previous", title: "Previous Track", subtitle: "Go to previous track in Spotify",
                relevanceScore: 0.85, keywords: ["spotify", "previous", "back", "rewind", "track"]
            ),
            RankingRow(
                id: "spotify/likeTrack", title: "Like / Unlike Current Track",
                subtitle: "Toggle current track in Liked Songs", relevanceScore: 0.8,
                keywords: ["spotify", "like", "unlike", "save", "heart", "favourite", "favorite", "liked"]
            ),
            RankingRow(
                id: "spotify/search", title: "Search Spotify", subtitle: "Play a song, album, artist or playlist",
                relevanceScore: 0.9,
                keywords: [
                    "spotify", "search", "find", "music", "play", "song", "track", "album", "artist", "playlist",
                ],
                hasParameters: true
            ),
            RankingRow(
                id: "spotify/quickSearch", title: "Open Spotify Search", subtitle: "Search in Spotify app",
                relevanceScore: 0.6, keywords: ["spotify", "search", "find", "open"], hasParameters: true
            ),
        ]
    }

    /// `AIAction.forSession` for the most recent sessions, the alternate resume row
    /// (`AnthropicProvider.alternateActions`), and the module's search action. The
    /// `awaiting` session gets the "waiting" keyword a waiting session carries.
    private static func claude(awaiting: String?) -> [any Action] {
        let sessions: [(id: String, title: String, branch: String)] = [
            ("mind", "teach the picker to read my mind", "feat/mind-reading"),
            ("release", "fix the release workflow", "fix/release"),
            ("lint", "split long files for swiftlint", "fix/lint-file-length"),
        ]
        var rows: [any Action] = sessions.enumerated().map { index, session in
            let id = "anthropic/session.\(session.id)"
            return RankingRow(
                id: id, title: session.title,
                subtitle: "Claude Code · ~/code/vibeshed · claude-opus-4-5 · \(index + 1) hr. ago",
                relevanceScore: rankedScore(index: index),
                keywords: [
                    "ai", "session", "chat", "claudecode", session.title, " users idmitriev code vibeshed",
                    session.branch,
                ] + (id == awaiting ? ["waiting"] : []),
                isAwaitingUser: id == awaiting
            )
        }
        rows.append(RankingRow(
            id: "anthropic/openInDesktop.mind", title: "teach the picker to read my mind — open in Claude Desktop",
            subtitle: "Continue this session in the desktop app", relevanceScore: 0.35,
            keywords: ["desktop", "app", "gui"]
        ))
        rows.append(RankingRow(
            id: "anthropic/search", title: "Search Claude Sessions", subtitle: "Search across Claude session history",
            relevanceScore: 0.9, keywords: ["ai", "search", "session", "history", "anthropic"], hasParameters: true
        ))
        return rows
    }

    /// `CalendarModule.buildEventActions` (relevance from `computeRelevance`, keywords
    /// from `buildKeywords`) and `buildOpenCalendarAction`.
    private static func calendar(now: Date, pairingStartsIn: Double?) -> [any Action] {
        var rows: [any Action] = [
            RankingRow(
                id: "calendar/openCalendar", title: "Open Calendar", subtitle: "Open Calendar.app",
                relevanceScore: 0.4, keywords: ["calendar", "open", "launch"]
            ),
        ]
        if let minutes = pairingStartsIn {
            let start = now.addingTimeInterval(minutes * 60)
            let relevance = minutes <= 0 ? 0.95 : minutes <= 15 ? 0.9 : minutes <= 60 ? 0.8 : 0.75
            rows.append(RankingRow(
                id: pairingEvent, title: "Pairing session", subtitle: "10:30 AM – 11:30 AM • Work",
                relevanceScore: relevance,
                keywords: ["calendar", "event", "meeting", "pairing", "session", "work"],
                scheduledStart: start, scheduledEnd: start.addingTimeInterval(3600)
            ))
        }
        return rows
    }
}

/// A mirrored row: an action with no behavior of its own.
struct RankingRow: Action {
    let id: ActionID
    let title: String
    let subtitle: String
    let iconName: String? = nil
    let relevanceScore: Double
    let keywords: [String]
    let parameters: [ActionParameter]
    let scheduledStart: Date?
    let scheduledEnd: Date?
    let isAwaitingUser: Bool

    init(
        id: String, title: String, subtitle: String, relevanceScore: Double, keywords: [String],
        hasParameters: Bool = false, scheduledStart: Date? = nil, scheduledEnd: Date? = nil,
        isAwaitingUser: Bool = false
    ) {
        self.id = ActionID(id)
        self.title = title
        self.subtitle = subtitle
        self.relevanceScore = relevanceScore
        self.keywords = keywords
        self.parameters = hasParameters
            ? [ActionParameter(id: "value", label: "Value", type: .text(placeholder: ""), isRequired: true)]
            : []
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.isAwaitingUser = isAwaitingUser
    }

    func run(with _: ParameterValues) async throws -> ActionResult {
        .dismiss
    }
}
