import Foundation

/// The concrete surface a session lives on (Claude Code CLI, Claude Desktop, Codex CLI…).
/// A vendor module owns several of these, so display identity travels with the session
/// rather than being switched on a vendor-wide enum.
struct AISessionSource: Sendable, Equatable {
    /// Stable identifier used in config `sources:` lists and action names.
    let id: String
    /// Compact label shown on the right of a list row, e.g. "CODE".
    let shortLabel: String
    /// Human label used in previews and subtitles, e.g. "Claude Code".
    let fullLabel: String
    let iconName: String
    let accent: AIAccent
}

/// Tint applied to a session's icon and preview pill. Kept as a symbolic case rather than
/// a `Color` so the session readers stay free of SwiftUI.
enum AIAccent: Sendable, Equatable {
    case orange
    case purple
    case green
    case teal
    case neutral
}

enum AIItemType: String, Sendable {
    case session
    case launcher
    case search
}

/// One resumable AI conversation, normalized across vendors and surfaces.
struct AISession: Sendable {
    /// Identifier used to resume on the session's own surface.
    let sessionID: String
    /// The CLI-side identifier when this session also exists as a CLI session,
    /// which lets a desktop session be resumed in a terminal and vice versa.
    let cliSessionID: String?
    let source: AISessionSource
    let title: String
    let lastPrompt: String?
    let project: String?
    /// Display name of the model the session last ran on, e.g. "Opus 5.5".
    let model: String?
    /// Git branch the session was working on, when the surface records it.
    let branch: String?
    let timestamp: Date
    /// What the session is blocked on until the user answers, e.g. "permission
    /// prompt" or "input needed"; nil while it works or sits idle.
    var waitingFor: String?

    init(
        sessionID: String,
        cliSessionID: String? = nil,
        source: AISessionSource,
        title: String,
        lastPrompt: String? = nil,
        project: String? = nil,
        model: String? = nil,
        branch: String? = nil,
        timestamp: Date,
        waitingFor: String? = nil
    ) {
        self.sessionID = sessionID
        self.cliSessionID = cliSessionID
        self.source = source
        self.title = title
        self.lastPrompt = lastPrompt
        self.project = project
        self.model = model
        self.branch = branch
        self.timestamp = timestamp
        self.waitingFor = waitingFor
    }

    /// A copy with the model and branch replaced by fresher values, such as ones read
    /// from the session's transcript. A nil argument keeps the current value.
    func updating(model: String?, branch: String?) -> AISession {
        AISession(
            sessionID: sessionID,
            cliSessionID: cliSessionID,
            source: source,
            title: title,
            lastPrompt: lastPrompt,
            project: project,
            model: model ?? self.model,
            branch: branch ?? self.branch,
            timestamp: timestamp,
            waitingFor: waitingFor
        )
    }

    /// Whether `query` matches this session's title, project or last prompt.
    func matches(lowercasedQuery query: String) -> Bool {
        title.lowercased().contains(query)
            || (lastPrompt?.lowercased().contains(query) ?? false)
            || (project?.lowercased().contains(query) ?? false)
    }
}
