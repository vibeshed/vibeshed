import Foundation

struct ShortcutsAction: Action {
    let id: ActionID
    let title: String
    let subtitle: String
    let iconName: String?
    let appIconPath: String?
    let relevanceScore: Double
    let keywords: [String]
    let parameters: [ActionParameter]

    private let runner: @Sendable (ParameterValues) async throws -> ActionResult

    init(
        id: ActionID,
        title: String,
        subtitle: String,
        iconName: String?,
        appIconPath: String? = ShortcutsModule.appPath,
        relevanceScore: Double,
        keywords: [String],
        parameters: [ActionParameter] = [],
        runner: @escaping @Sendable (ParameterValues) async throws -> ActionResult
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.appIconPath = appIconPath
        self.relevanceScore = relevanceScore
        self.keywords = keywords
        self.parameters = parameters
        self.runner = runner
    }

    func run(with values: ParameterValues) async throws -> ActionResult {
        try await runner(values)
    }
}
