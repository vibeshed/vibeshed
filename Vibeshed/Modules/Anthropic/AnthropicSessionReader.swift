import Foundation
import OSLog

private let log = Log.module("anthropic")

/// Reads Claude session history from disk: the Claude Code CLI's `history.jsonl` and
/// Claude Desktop's per-session metadata files, plus the model and branch from each
/// listed session's transcript and whether a running session is waiting on the user.
enum AnthropicSessionReader {
    /// Where the CLI and the desktop app keep session state.
    struct Locations {
        /// `~/.claude`: `history.jsonl`, the `projects/` transcripts and the
        /// `sessions/` records of running processes.
        var claudeDirectory: URL
        /// Claude Desktop's per-session metadata.
        var desktopSessionsDirectory: URL

        static var standard: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Locations(
                claudeDirectory: home.appendingPathComponent(".claude"),
                desktopSessionsDirectory: home.appendingPathComponent(
                    "Library/Application Support/Claude/claude-code-sessions"
                )
            )
        }
    }

    static func readSessions(
        sources: [String],
        limit: Int,
        locations: Locations = .standard
    ) -> [AISession] {
        let wantsDesktop = sources.contains(AnthropicProvider.claudeDesktop.id)
        let wantsCode = sources.contains(AnthropicProvider.claudeCode.id)

        // Desktop metadata is read first even when only CLI sessions are wanted:
        // it carries human-written titles for sessions the CLI only knows by prompt.
        let desktopMeta = (wantsDesktop || wantsCode)
            ? readDesktopMetadata(base: locations.desktopSessionsDirectory) : []
        let waiting = AnthropicLiveSessions.waiting(
            in: locations.claudeDirectory.appendingPathComponent("sessions")
        )

        var sessions: [AISession] = []
        if wantsCode {
            sessions += readClaudeCodeSessions(
                titles: titleLookup(desktopMeta),
                waiting: waiting,
                limit: limit,
                claudeDirectory: locations.claudeDirectory
            )
        }
        if wantsDesktop {
            // A desktop session that mirrors a CLI session we already listed would be
            // a duplicate row for the same conversation.
            let seen = Set(sessions.map(\.sessionID))
            sessions += desktopSessions(
                from: desktopMeta, waiting: waiting, excludingCLIIDs: seen
            )
        }

        sessions.sort(by: ranksBefore)
        log.debug("Anthropic sessions found: \(sessions.count, privacy: .public)")
        // Desktop sessions run on the CLI too, so both kinds have a transcript.
        return AnthropicTranscripts.enrich(
            Array(sessions.prefix(limit)),
            projectsDirectory: locations.claudeDirectory
                .appendingPathComponent("projects")
        )
    }

    /// Sessions waiting on the user first, then newest first, so the cap never drops
    /// one that is waiting.
    private static func ranksBefore(_ lhs: AISession, _ rhs: AISession) -> Bool {
        if (lhs.waitingFor == nil) != (rhs.waitingFor == nil) {
            return lhs.waitingFor != nil
        }
        return lhs.timestamp > rhs.timestamp
    }

    // MARK: - Claude Code CLI

    private static func readClaudeCodeSessions(
        titles: [String: String],
        waiting: [String: String],
        limit: Int,
        claudeDirectory: URL
    ) -> [AISession] {
        let path = claudeDirectory.appendingPathComponent("history.jsonl").path
        let entries = AIJSONL.objects(atPath: path).compactMap(CLIEntry.init)
        guard !entries.isEmpty else {
            log.debug("Claude Code history.jsonl missing or empty")
            return []
        }

        let sessions = Dictionary(grouping: entries, by: \.sessionID)
            .compactMap { sessionID, group -> AISession? in
                let sorted = group.sorted { $0.timestamp < $1.timestamp }
                guard let first = sorted.first, let last = sorted.last else {
                    return nil
                }
                return AISession(
                    sessionID: sessionID,
                    cliSessionID: sessionID,
                    source: AnthropicProvider.claudeCode,
                    title: titles[sessionID]
                        ?? cliTitle(first.display, sessionID: sessionID),
                    lastPrompt: last.display.asSessionTitle(limit: 500),
                    project: first.project,
                    timestamp: Date(timeIntervalSince1970: last.timestamp / 1000),
                    waitingFor: waiting[sessionID]
                )
            }
            .sorted(by: ranksBefore)
        return Array(sessions.prefix(limit))
    }

    /// Slash commands make poor titles, so those fall back to a short session label.
    private static func cliTitle(_ display: String, sessionID: String) -> String {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), let title = trimmed.asSessionTitle() else {
            return "Session \(sessionID.prefix(8))"
        }
        return title
    }

    // MARK: - Claude Desktop

    private static func desktopSessions(
        from metas: [DesktopMeta],
        waiting: [String: String],
        excludingCLIIDs excluded: Set<String>
    ) -> [AISession] {
        metas.compactMap { meta in
            guard !meta.isArchived else { return nil }
            if let cliID = meta.cliSessionID, excluded.contains(cliID) {
                return nil
            }
            return AISession(
                sessionID: meta.sessionID,
                cliSessionID: meta.cliSessionID,
                source: AnthropicProvider.claudeDesktop,
                title: meta.title ?? "Session \(meta.sessionID.prefix(8))",
                project: meta.cwd,
                model: meta.model.map(AnthropicModelName.displayName(for:)),
                branch: meta.branch,
                timestamp: Date(timeIntervalSince1970: meta.lastActivityAt / 1000),
                waitingFor: waiting[meta.sessionID]
                    ?? meta.cliSessionID.flatMap { waiting[$0] }
            )
        }
    }

    /// Titles keyed by CLI session ID, so a CLI session shows the name its desktop
    /// counterpart was given.
    private static func titleLookup(_ metas: [DesktopMeta]) -> [String: String] {
        var lookup: [String: String] = [:]
        for meta in metas {
            guard let cliID = meta.cliSessionID, let title = meta.title else {
                continue
            }
            if lookup[cliID] == nil { lookup[cliID] = title }
        }
        return lookup
    }

    /// Walks `…/Claude/claude-code-sessions/<account>/<session>/*.json`.
    private static func readDesktopMetadata(base: URL) -> [DesktopMeta] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else {
            log.debug("Claude Desktop sessions directory not found")
            return []
        }
        return subdirectories(of: base, fm: fm)
            .flatMap { subdirectories(of: $0, fm: fm) }
            .flatMap { sessionDir -> [DesktopMeta] in
                let files = (try? fm.contentsOfDirectory(atPath: sessionDir.path))
                    ?? []
                return files
                    .filter { $0.hasSuffix(".json") }
                    .compactMap { file in
                        AIJSONL
                            .object(at: sessionDir.appendingPathComponent(file))
                            .flatMap(DesktopMeta.init)
                    }
            }
    }

    private static func subdirectories(
        of url: URL,
        fm: FileManager
    ) -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        return names.compactMap { name in
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir),
                  isDir.boolValue
            else { return nil }
            return child
        }
    }
}

// MARK: - Raw records

private struct CLIEntry {
    let display: String
    let timestamp: Double
    let project: String?
    let sessionID: String

    init?(_ json: [String: Any]) {
        guard let display = json["display"] as? String,
              let timestamp = json["timestamp"] as? Double,
              let sessionID = json["sessionId"] as? String
        else { return nil }
        self.display = display
        self.timestamp = timestamp
        self.sessionID = sessionID
        project = json["project"] as? String
    }
}

private struct DesktopMeta {
    let sessionID: String
    let cliSessionID: String?
    let title: String?
    let cwd: String?
    let model: String?
    /// Set for sessions the app started in a worktree it created.
    let branch: String?
    let lastActivityAt: Double
    let isArchived: Bool

    init?(_ json: [String: Any]) {
        guard let sessionID = json["sessionId"] as? String,
              let lastActivityAt = json["lastActivityAt"] as? Double
        else { return nil }
        self.sessionID = sessionID
        self.lastActivityAt = lastActivityAt
        cliSessionID = json["cliSessionId"] as? String
        title = json["title"] as? String
        cwd = json["cwd"] as? String
        model = json["model"] as? String
        branch = json["branch"] as? String
        isArchived = json["isArchived"] as? Bool ?? false
    }
}
