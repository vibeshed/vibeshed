import Foundation

/// Codex sessions, from both the CLI and the Codex desktop app — they share one
/// on-disk thread store under `~/.codex`.
struct OpenAIProvider: AIProvider {
    typealias Config = OpenAIConfig

    static let moduleID = "openai"
    static let displayName = "Codex"
    static let iconName = "terminal.fill"
    static let defaultConfig = OpenAIConfig()

    static let codex = AISessionSource(
        id: "codex",
        shortLabel: "CODEX",
        fullLabel: "Codex",
        iconName: "terminal.fill",
        accent: .green
    )

    static let allSources = [codex]

    static func validate(_ config: OpenAIConfig) -> ConfigValidationResult {
        var errors = validateCommon(config).errors
        if let path = config.codexPath, !path.isEmpty,
           !FileManager.default.fileExists(atPath: path)
        {
            errors.append("codexPath does not exist: \(path)")
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

    func readSessions(config: OpenAIConfig, limit: Int) -> [AISession] {
        guard config.sources.contains(Self.codex.id) else { return [] }
        return OpenAISessionReader.readSessions(limit: limit)
    }

    func openSession(_ session: AISession, config _: OpenAIConfig) {
        AILaunch.openURL(OpenAIDeeplink.thread(session.sessionID, hostID: session.host?.id))
    }

    static func cli(_ config: OpenAIConfig) -> String {
        AILaunch.resolveCLI(
            customPath: config.codexPath,
            candidates: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
            fallbackName: "codex"
        )
    }

    // MARK: - Launchers

    func launcherActions(config: OpenAIConfig) -> [AIAction] {
        OpenAILaunchers.makeActions(config: config)
    }
}
