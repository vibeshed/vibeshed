import Foundation

/// Claude Code CLI and Claude Desktop sessions.
struct AnthropicProvider: AIProvider {
    typealias Config = AnthropicConfig

    static let moduleID = "anthropic"
    static let displayName = "Claude"
    static let iconName = "brain"
    static let defaultConfig = AnthropicConfig()

    static let claudeCode = AISessionSource(
        id: "claudeCode",
        shortLabel: "CODE",
        fullLabel: "Claude Code",
        iconName: "terminal",
        accent: .orange
    )

    static let claudeDesktop = AISessionSource(
        id: "claudeDesktop",
        shortLabel: "DESKTOP",
        fullLabel: "Claude Desktop",
        iconName: "brain",
        accent: .purple
    )

    static let allSources = [claudeCode, claudeDesktop]

    static func validate(_ config: AnthropicConfig) -> ConfigValidationResult {
        var errors = validateCommon(config).errors
        if let path = config.claudePath, !path.isEmpty,
           !FileManager.default.fileExists(atPath: path)
        {
            errors.append("claudePath does not exist: \(path)")
        }
        if let terminal = config.terminalApp,
           !["iterm", "terminal"].contains(terminal)
        {
            errors.append(
                "Invalid terminalApp: '\(terminal)'. Valid: iterm, terminal"
            )
        }
        return errors.isEmpty ? .valid : .invalid(errors)
    }

    // MARK: - Sessions

    func readSessions(config: AnthropicConfig, limit: Int) -> [AISession] {
        AnthropicSessionReader.readSessions(
            sources: config.sources, limit: limit
        )
    }

    /// A session that is still running is taken back to where it runs: its Claude
    /// Desktop tab or its terminal tab. Resuming it would start a second process on
    /// the same conversation.
    func openSession(_ session: AISession, config: AnthropicConfig) {
        guard let live = (session.cliSessionID ?? cliID(of: session))
            .flatMap({ AnthropicLiveSessions.running($0) })
        else {
            reopen(session, config: config)
            return
        }
        if let host = live.hostSessionID,
           AnthropicDeeplink.isDesktopSessionID(host),
           let url = AnthropicDeeplink.continueCodeSession(host)
        {
            AILaunch.openURL(url)
            return
        }
        AITerminalFocus.focus(pid: live.pid) {
            reopen(session, config: config)
        }
    }

    private func reopen(_ session: AISession, config: AnthropicConfig) {
        switch session.source.id {
        case Self.claudeDesktop.id:
            openInDesktop(session)
        default:
            if config.resumeIn == .desktop, canOpenInDesktop(session) {
                openInDesktop(session)
            } else {
                resumeInTerminal(session, config: config)
            }
        }
    }

    /// Offers each session its other surface: a CLI session can be handed to the
    /// desktop app, and a desktop session with a CLI id can drop into a terminal.
    func alternateActions(
        for session: AISession,
        config: AnthropicConfig
    ) -> [AIAction] {
        guard config.showAlternateResume else { return [] }
        let isDesktop = session.source.id == Self.claudeDesktop.id
        let wantsDesktopPrimary = config.resumeIn == .desktop
        // The primary action already covers this surface.
        let alternateIsDesktop = isDesktop ? false : !wantsDesktopPrimary

        if alternateIsDesktop {
            guard canOpenInDesktop(session) else { return [] }
            return [
                alternate(
                    session,
                    .init(
                        name: "openInDesktop",
                        titleSuffix: "open in Claude Desktop",
                        subtitle: "Continue this session in the desktop app",
                        icon: "macwindow",
                        keywords: ["desktop", "app", "gui"]
                    )
                ) { openInDesktop(session) },
            ]
        }
        guard session.cliSessionID != nil else { return [] }
        return [
            alternate(
                session,
                .init(
                    name: "openInTerminal",
                    titleSuffix: "resume in terminal",
                    subtitle: "Continue this session with the claude CLI",
                    icon: "terminal",
                    keywords: ["terminal", "cli", "resume"]
                )
            ) { resumeInTerminal(session, config: config) },
        ]
    }

    /// The differing half of an alternate-surface row.
    private struct AlternateSpec {
        let name: String
        let titleSuffix: String
        let subtitle: String
        let icon: String
        let keywords: [String]
    }

    private func alternate(
        _ session: AISession,
        _ spec: AlternateSpec,
        run: @escaping @Sendable () -> Void
    ) -> AIAction {
        AIAction(
            id: ActionID(
                module: Self.moduleID,
                name: "\(spec.name).\(StableID.hash(session.sessionID))"
            ),
            title: "\(session.title) — \(spec.titleSuffix)",
            subtitle: spec.subtitle,
            iconName: spec.icon,
            // Ranked below the session's primary row so the default way to reopen
            // a session always sorts first.
            relevanceScore: 0.35,
            keywords: ["claude", "session"] + spec.keywords,
            moduleName: Self.displayName,
            source: session.source,
            itemType: .session,
            projectPath: session.project,
            modelName: session.model,
            branch: session.branch,
            sessionTimestamp: session.timestamp
        ) { _ in
            run()
            return .dismiss
        }
    }

    // MARK: - Opening

    private func canOpenInDesktop(_ session: AISession) -> Bool {
        guard AnthropicDeeplink.isInstalled else { return false }
        return desktopURL(for: session) != nil
    }

    private func desktopURL(for session: AISession) -> String? {
        if session.source.id == Self.claudeDesktop.id,
           AnthropicDeeplink.isDesktopSessionID(session.sessionID)
        {
            return AnthropicDeeplink.continueCodeSession(session.sessionID)
        }
        // A CLI session is imported into the desktop app by its UUID.
        return session.cliSessionID
            .flatMap(AnthropicDeeplink.resumeCLISession)
    }

    private func openInDesktop(_ session: AISession) {
        if let url = desktopURL(for: session) {
            AILaunch.openURL(url)
        } else {
            AILaunch.openApp(bundleID: AnthropicDeeplink.bundleID)
        }
    }

    private func resumeInTerminal(_ session: AISession, config: AnthropicConfig) {
        guard let id = session.cliSessionID ?? cliID(of: session) else {
            openInDesktop(session)
            return
        }
        AILaunch.inTerminal(
            command: "\(Self.cli(config)) --resume \(id)",
            cwd: session.project,
            terminalApp: config.terminalApp
        )
    }

    private func cliID(of session: AISession) -> String? {
        AnthropicDeeplink.isCLISessionID(session.sessionID)
            ? session.sessionID : nil
    }

    static func cli(_ config: AnthropicConfig) -> String {
        AILaunch.resolveCLI(
            customPath: config.claudePath,
            candidates: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            fallbackName: "claude"
        )
    }

    // MARK: - Launchers

    func launcherActions(config: AnthropicConfig) -> [AIAction] {
        AnthropicLaunchers.makeActions(config: config)
    }
}
