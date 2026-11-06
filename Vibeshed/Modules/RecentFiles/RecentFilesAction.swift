import SwiftUI

struct RecentFilesAction: Action {
    let id: ActionID
    let title: String
    let subtitle: String
    let iconName: String?
    /// The app that opens the file, shown for the selected row.
    let appIconPath: String?
    let relevanceScore: Double
    let keywords: [String]
    let parameters: [ActionParameter]
    let file: RecentFile?
    /// File rows: names like "Screenshot 2026-10-30 at 16.35.57.png" would fuzzy-match
    /// nearly any short query.
    let requiresWordPrefixMatch: Bool

    private let runner: @Sendable (ParameterValues) async throws -> ActionResult

    init(
        id: ActionID,
        title: String,
        subtitle: String,
        iconName: String?,
        appIconPath: String? = nil,
        relevanceScore: Double,
        keywords: [String] = [],
        parameters: [ActionParameter] = [],
        file: RecentFile? = nil,
        requiresWordPrefixMatch: Bool = false,
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
        self.file = file
        self.requiresWordPrefixMatch = requiresWordPrefixMatch
        self.runner = runner
    }

    func run(with values: ParameterValues) async throws -> ActionResult {
        try await runner(values)
    }

    /// A file row shows its type's Finder icon.
    @MainActor
    func makeListItemView() -> AnyView? {
        file.map { AnyView(RecentFileListItemView(file: $0)) }
    }

    @MainActor
    func makePreviewView() -> AnyView? {
        file.map { AnyView(RecentFilePreview(file: $0, appPath: appIconPath)) }
    }
}
