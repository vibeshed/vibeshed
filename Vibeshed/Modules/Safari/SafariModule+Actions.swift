import SwiftUI

// MARK: - Fixed actions

extension SafariModule {
    func fixedActions() -> [SafariAction] {
        [
            searchAction(
                name: "searchHistory",
                title: "Search Safari History",
                subtitle: "Find a page you visited in Safari",
                iconName: "clock.arrow.circlepath",
                keywords: ["safari", "history", "search", "visited", "pages", "recent"]
            ),
            searchAction(
                name: "searchFavorites",
                title: "Search Safari Favorites",
                subtitle: "Open one of your Favorites in Safari",
                iconName: "star",
                keywords: ["safari", "favorites", "favourites", "bookmarks", "search"]
            ),
            searchAction(
                name: "searchCloudTabs",
                title: "Search iCloud Tabs",
                subtitle: "Open a tab from Safari on your other devices",
                iconName: "icloud",
                keywords: ["safari", "icloud", "tabs", "cloud", "devices", "iphone", "ipad", "handoff"]
            ),
        ]
    }

    private func searchAction(
        name: String,
        title: String,
        subtitle: String,
        iconName: String,
        keywords: [String]
    ) -> SafariAction {
        SafariAction(
            id: ActionID(module: "safari", name: name),
            title: title,
            subtitle: subtitle,
            iconName: iconName,
            appIconPath: safariPath,
            relevanceScore: 0.85,
            keywords: keywords,
            parameters: [
                ActionParameter(
                    id: "page",
                    label: "Page",
                    type: .dynamicSelection(hint: "page"),
                    isRequired: true,
                    // History is ranked here, by match and visits; Favorites and tabs are
                    // fuzzy-matched here, as the picker would, so the row saying a source
                    // can't be read isn't filtered out by the page name being typed.
                    rankedByModule: true
                ),
            ]
        ) { [self] values in
            // The only option without an address is the one saying Safari's data can't be read.
            guard let url = values["page"], !url.isEmpty else {
                throw await sourceError(for: name) ?? SafariModuleError.nothingChosen
            }
            try await open(url)
            return .dismiss
        }
    }

    private func sourceError(for searchName: String) -> Error? {
        switch searchName {
        case "searchHistory": historyError
        case "searchFavorites": favoritesError
        default: cloudTabsError
        }
    }
}

// MARK: - Rows

extension SafariModule {
    static func actionID(prefix: String, _ key: String) -> ActionID {
        ActionID(module: "safari", name: prefix + StableID.hash(key))
    }

    func historyAction(_ match: SafariHistoryIndex.Match) -> SafariAction {
        let page = SafariPage.history(match.entry)
        return row(
            page,
            id: Self.actionID(prefix: Self.historyPrefix, match.entry.url),
            // The path tells a site's pages apart and holds the words the picker's
            // word-prefix gate checks besides the title. Not keywords: a keyword equal to
            // the query counts as much as the title, which would put any page with the
            // word somewhere in its address above fixed actions named for it.
            subtitle: page.address,
            // Frequent, recent pages ahead of comparable matches; below Favorites and tabs.
            relevance: 0.3 + 0.2 * match.frecency,
            keywords: [],
            requiresWordPrefixMatch: true
        )
    }

    func favoriteAction(_ favorite: SafariFavorite) -> SafariAction {
        let page = SafariPage.favorite(favorite)
        let folders = (["Favorites"] + favorite.folders).joined(separator: " › ")
        return row(
            page,
            id: Self.actionID(prefix: Self.favoritePrefix, favorite.url),
            subtitle: "\(folders) · \(page.site)",
            relevance: 0.6,
            keywords: ["favorite", "favourite", page.site] + favorite.folders.map { $0.lowercased() }
        )
    }

    func cloudTabAction(_ tab: SafariCloudTab) -> SafariAction {
        let page = SafariPage.cloudTab(tab)
        return row(
            page,
            id: Self.actionID(prefix: Self.cloudTabPrefix, tab.device.id + tab.url),
            subtitle: "\(tab.device.name) · \(page.site)",
            relevance: 0.55,
            keywords: ["icloud", "tab", page.site, tab.device.name.lowercased()],
            iconName: tab.device.symbolName
        )
    }

    private func row(
        _ page: SafariPage,
        id: ActionID,
        subtitle: String,
        relevance: Double,
        keywords: [String],
        iconName: String? = nil,
        requiresWordPrefixMatch: Bool = false
    ) -> SafariAction {
        let url = page.url
        return SafariAction(
            id: id,
            title: page.title,
            subtitle: subtitle,
            iconName: iconName ?? "safari",
            // A tab shows the device it's open on rather than Safari.
            appIconPath: iconName == nil ? safariPath : nil,
            relevanceScore: relevance,
            keywords: keywords,
            page: page,
            requiresWordPrefixMatch: requiresWordPrefixMatch
        ) { [self] _ in
            try await open(url)
            return .dismiss
        }
    }
}

// MARK: - Search options

extension SafariModule {
    func provideParameterOptions(for parameterID: String, in actionID: ActionID, query: String) async
        -> [ParameterOption]
    {
        guard parameterID == "page" else { return [] }
        switch actionID.actionName {
        case "searchHistory":
            await loadHistoryIfNeeded()
            if history.isEmpty, let historyError {
                return [Self.failureOption("Couldn't read Safari's history", historyError)]
            }
            return history.search(query, mode: .anywhere, limit: Self.searchLimit).map { match in
                historyOption(match.entry, query: query)
            }
        case "searchFavorites":
            refreshFavoritesIfChanged()
            if favorites.isEmpty, let favoritesError {
                return [Self.failureOption("Couldn't read your Favorites", favoritesError)]
            }
            return Self.matching(favorites.map(favoriteOption), query)
        case "searchCloudTabs":
            refreshCloudTabsIfChanged()
            if cloudTabs.isEmpty, let cloudTabsError {
                return [Self.failureOption("Couldn't read iCloud Tabs", cloudTabsError)]
            }
            return Self.matching(cloudTabs.map(cloudTabOption), query)
        default:
            return []
        }
    }

    func historyOption(_ entry: SafariHistoryEntry, query: String) -> ParameterOption {
        let page = SafariPage.history(entry)
        var option = ParameterOption(
            id: entry.url,
            label: page.title,
            subtitle: "\(page.address) · \(SafariPagePreview.relative(entry.lastVisited))",
            iconURL: safariPath.map { URL(fileURLWithPath: $0) },
            makePreview: preview(page)
        )
        let ranges = Self.highlights(of: query, in: option.label)
        option.labelHighlightRanges = ranges.isEmpty ? nil : ranges
        return option
    }

    func favoriteOption(_ favorite: SafariFavorite) -> ParameterOption {
        let page = SafariPage.favorite(favorite)
        let folder = favorite.folders.joined(separator: " › ")
        return ParameterOption(
            id: favorite.url,
            label: page.title,
            subtitle: folder.isEmpty ? page.site : "\(folder) · \(page.site)",
            iconURL: safariPath.map { URL(fileURLWithPath: $0) },
            keywords: [page.site] + favorite.folders.map { $0.lowercased() },
            makePreview: preview(page)
        )
    }

    func cloudTabOption(_ tab: SafariCloudTab) -> ParameterOption {
        let page = SafariPage.cloudTab(tab)
        return ParameterOption(
            id: tab.url,
            label: page.title,
            subtitle: "\(tab.device.name) · \(page.site)",
            iconName: tab.device.symbolName,
            keywords: [page.site, tab.device.name.lowercased()],
            makePreview: preview(page)
        )
    }

    private func preview(_ page: SafariPage) -> @MainActor @Sendable () -> AnyView {
        let safariPath = safariPath
        return { AnyView(SafariPagePreview(page: page, safariPath: safariPath)) }
    }

    /// `options` fuzzy-matched against `query` the way the picker matches options it ranks
    /// itself; all of them, in order, with nothing typed.
    static func matching(_ options: [ParameterOption], _ query: String) -> [ParameterOption] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? options : options.fuzzyFiltered(by: query)
    }

    /// Where each word of `query` first appears in `label`, for options the module ranks.
    static func highlights(of query: String, in label: String) -> [Range<String.Index>] {
        query.split(whereSeparator: \.isWhitespace).compactMap { word in
            label.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        }
    }

    static func failureOption(_ label: String, _ error: Error) -> ParameterOption {
        ParameterOption(
            id: "",
            label: label,
            subtitle: error.localizedDescription,
            iconName: "exclamationmark.triangle"
        )
    }
}
