import Foundation
import SwiftUI

/// One picker row produced by an AI vendor module. Vendor-agnostic: everything the
/// list row and preview need to render travels in `source` and the metadata fields,
/// so both the Anthropic and OpenAI modules reuse the same views.
struct AIAction: Action {
    let id: ActionID
    let title: String
    let subtitle: String
    let iconName: String?
    let relevanceScore: Double
    let keywords: [String]
    let parameters: [ActionParameter]

    /// Owning module's display name, shown on the preview's module badge.
    let moduleName: String
    let source: AISessionSource?
    let itemType: AIItemType
    let projectPath: String?
    let modelName: String?
    let branch: String?
    let sessionTimestamp: Date?
    /// What the session is blocked on until the user answers (see `AISession.waitingFor`).
    let waitingFor: String?

    var isAwaitingUser: Bool {
        waitingFor != nil
    }

    private let runner: @Sendable (
        ParameterValues
    ) async throws -> ActionResult

    init(
        id: ActionID,
        title: String,
        subtitle: String,
        iconName: String? = nil,
        relevanceScore: Double = 0.8,
        keywords: [String] = [],
        parameters: [ActionParameter] = [],
        moduleName: String,
        source: AISessionSource? = nil,
        itemType: AIItemType = .launcher,
        projectPath: String? = nil,
        modelName: String? = nil,
        branch: String? = nil,
        sessionTimestamp: Date? = nil,
        waitingFor: String? = nil,
        runner: @escaping @Sendable (
            ParameterValues
        ) async throws -> ActionResult
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.relevanceScore = relevanceScore
        self.keywords = keywords
        self.parameters = parameters
        self.moduleName = moduleName
        self.source = source
        self.itemType = itemType
        self.projectPath = projectPath
        self.modelName = modelName
        self.branch = branch
        self.sessionTimestamp = sessionTimestamp
        self.waitingFor = waitingFor
        self.runner = runner
    }

    func run(with values: ParameterValues) async throws -> ActionResult {
        try await runner(values)
    }

    @MainActor
    func makeListItemView() -> AnyView? {
        AnyView(AIActionListItemView(action: self))
    }

    @MainActor
    func makePreviewView() -> AnyView? {
        AnyView(AIActionPreviewView(action: self))
    }
}

/// Identifies the module producing an action: `id` namespaces its `ActionID`s,
/// `displayName` labels its preview badge.
struct AIModuleIdentity: Sendable {
    let id: String
    let displayName: String
}

extension AIAction {
    /// The display side of a quick-launch action, separated from the module identity
    /// and the work so both vendor modules build launchers the same way.
    struct LauncherSpec {
        let name: String
        let title: String
        let subtitle: String
        let icon: String
        let keywords: [String]
        var parameters: [ActionParameter] = []
    }

    /// Builds a launcher row that runs `perform` and dismisses the picker.
    static func launcher(
        _ spec: LauncherSpec,
        module: AIModuleIdentity,
        perform: @escaping @Sendable (ParameterValues) -> Void
    ) -> AIAction {
        AIAction(
            id: ActionID(module: module.id, name: spec.name),
            title: spec.title,
            subtitle: spec.subtitle,
            iconName: spec.icon,
            relevanceScore: 0.7,
            keywords: ["ai"] + spec.keywords,
            parameters: spec.parameters,
            moduleName: module.displayName,
            itemType: .launcher
        ) { values in
            perform(values)
            return .dismiss
        }
    }

    /// Builds the picker row for a session, wiring `open` as the activation handler.
    /// Shared by the recent-sessions list and by search results, which differ only in
    /// action-name prefix and score decay.
    static func forSession(
        _ session: AISession,
        module: AIModuleIdentity,
        namePrefix: String,
        relevanceScore: Double,
        open: @escaping @Sendable () -> Void
    ) -> AIAction {
        AIAction(
            id: ActionID(
                module: module.id,
                name: "\(namePrefix).\(StableID.hash(session.sessionID))"
            ),
            title: session.title,
            subtitle: sessionSubtitle(session),
            iconName: session.source.iconName,
            relevanceScore: relevanceScore,
            keywords: sessionKeywords(session),
            moduleName: module.displayName,
            source: session.source,
            itemType: .session,
            projectPath: session.project,
            modelName: session.model,
            branch: session.branch,
            sessionTimestamp: session.timestamp,
            waitingFor: session.waitingFor
        ) { _ in
            open()
            return .dismiss
        }
    }

    private static func sessionKeywords(_ session: AISession) -> [String] {
        var keywords = [
            "ai", "session", "chat",
            session.source.id.lowercased(),
            session.title.lowercased(),
        ]
        if let project = session.project {
            keywords.append(
                project.lowercased().replacingOccurrences(of: "/", with: " ")
            )
        }
        if let branch = session.branch {
            keywords.append(branch.lowercased())
        }
        if session.waitingFor != nil {
            keywords.append("waiting")
        }
        return keywords
    }

    private static func sessionSubtitle(_ session: AISession) -> String {
        var parts = [session.source.fullLabel]
        if let project = session.project {
            parts.append(abbreviatePath(project))
        }
        if let model = session.model {
            parts.append(model)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        parts.append(
            formatter.localizedString(for: session.timestamp, relativeTo: Date())
        )
        return parts.joined(separator: " · ")
    }
}
