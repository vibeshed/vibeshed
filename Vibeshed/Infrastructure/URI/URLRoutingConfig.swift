import Foundation

struct URLRoutingRule: Codable, Sendable, Equatable {
    let pattern: String
    let browser: String?
    let profile: String?
    let action: String?
}

struct URLRoutingConfig: Codable, Sendable, Equatable {
    var rules: [URLRoutingRule] = []
    var defaultBrowser: String?
    var defaultProfile: String?
    var registerAsDefaultBrowser: Bool = true
    /// Apps from `DeepLinkCatalog` whose links open in the app, when it's installed, before
    /// any rule applies.
    var openInApps: [String] = ["zoom"]
}

extension URLRoutingConfig {
    /// Every key is optional: a missing one keeps its default above. Synthesized
    /// Decodable would throw keyNotFound instead, and `ConfigManager` would then drop the
    /// whole section for the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        rules = try container.decodeIfPresent([URLRoutingRule].self, forKey: .rules) ?? defaults.rules
        defaultBrowser = try container.decodeIfPresent(String.self, forKey: .defaultBrowser)
        defaultProfile = try container.decodeIfPresent(String.self, forKey: .defaultProfile)
        registerAsDefaultBrowser = try container.decodeIfPresent(Bool.self, forKey: .registerAsDefaultBrowser)
            ?? defaults.registerAsDefaultBrowser
        openInApps = try container.decodeIfPresent([String].self, forKey: .openInApps) ?? defaults.openInApps
    }
}
