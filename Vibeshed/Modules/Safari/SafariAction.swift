import SwiftUI

/// What a Safari row or option opens.
enum SafariPage: Sendable, Equatable {
    case history(SafariHistoryEntry)
    case favorite(SafariFavorite)
    case cloudTab(SafariCloudTab)

    var url: String {
        switch self {
        case let .history(entry): entry.url
        case let .favorite(favorite): favorite.url
        case let .cloudTab(tab): tab.url
        }
    }

    var title: String {
        switch self {
        case let .history(entry): entry.displayTitle
        case let .favorite(favorite): favorite.displayTitle
        case let .cloudTab(tab): tab.displayTitle
        }
    }

    /// Host and path, for telling a site's pages apart.
    var address: String {
        SafariURL.address(url)
    }

    /// The host without "www.", for subtitles.
    var site: String {
        let host = SafariURL.host(url)
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct SafariAction: Action {
    let id: ActionID
    let title: String
    let subtitle: String
    let iconName: String?
    let appIconPath: String?
    let relevanceScore: Double
    let keywords: [String]
    let parameters: [ActionParameter]
    let page: SafariPage?
    /// History rows: long titles would fuzzy-match nearly any short query.
    let requiresWordPrefixMatch: Bool

    private let runner: @Sendable (ParameterValues) async throws -> ActionResult

    init(
        id: ActionID,
        title: String,
        subtitle: String,
        iconName: String?,
        appIconPath: String?,
        relevanceScore: Double,
        keywords: [String] = [],
        parameters: [ActionParameter] = [],
        page: SafariPage? = nil,
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
        self.page = page
        self.requiresWordPrefixMatch = requiresWordPrefixMatch
        self.runner = runner
    }

    func run(with values: ParameterValues) async throws -> ActionResult {
        try await runner(values)
    }

    /// One row per address across Safari's sources, open browser tabs and other
    /// modules' bookmarks and history.
    var deduplicationKey: String? {
        page.map { ActionScorer.normalizeURL($0.url) }
    }

    @MainActor
    func makePreviewView() -> AnyView? {
        page.map { AnyView(SafariPagePreview(page: $0, safariPath: appIconPath)) }
    }
}
