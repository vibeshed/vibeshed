import Foundation

struct SafariConfig: Codable, Sendable, Equatable {
    /// Pages from Safari's history listed in the main search for a query of three or more
    /// letters whose words start words of the page's title or address; 0 lists none.
    /// Search Safari History always covers every page.
    var historyResults = 8

    /// Safari's Favorites as rows of the main search.
    var showFavorites = true

    /// Tabs open in Safari on your other devices (iCloud Tabs) as rows of the main search.
    var showCloudTabs = true

    /// Action name suffixes to expose (nil = all): `searchHistory`, `searchFavorites`,
    /// `searchCloudTabs`, or the row families `history`, `favorite`, `cloudTab`.
    var enabledActions: Set<String>?

    init() {}

    /// Decodes each field leniently: Codable synthesis ignores Swift property
    /// defaults, and a user's section may specify only some keys.
    init(from decoder: Decoder) throws {
        let defaults = SafariConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        historyResults = try container.decodeIfPresent(Int.self, forKey: .historyResults) ?? defaults.historyResults
        showFavorites = try container.decodeIfPresent(Bool.self, forKey: .showFavorites) ?? defaults.showFavorites
        showCloudTabs = try container.decodeIfPresent(Bool.self, forKey: .showCloudTabs) ?? defaults.showCloudTabs
        enabledActions = try container.decodeIfPresent(Set<String>.self, forKey: .enabledActions)
    }

    private enum CodingKeys: String, CodingKey {
        case historyResults
        case showFavorites
        case showCloudTabs
        case enabledActions
    }
}
