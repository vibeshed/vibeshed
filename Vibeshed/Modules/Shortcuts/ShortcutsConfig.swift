import Foundation

struct ShortcutsConfig: Codable, Sendable, Equatable {
    /// Shortcuts in this folder are searches: each gets a row that runs it with what's typed
    /// and lists what it outputs. Every other shortcut gets a row that runs it. Empty makes
    /// every shortcut a plain one.
    var searchFolder = "Vibeshed"
    /// Seconds a search shortcut has to answer before it's stopped. One that asks for
    /// input would otherwise wait for an answer nobody sees.
    var searchTimeout: Double = 10
    /// Shortcut names left out of the picker.
    var excluded: [String] = []
}

extension ShortcutsConfig {
    /// Every key is optional: a missing one keeps its default above instead of failing
    /// the whole section (see `ApplicationConfig`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        searchFolder = try container.decodeIfPresent(String.self, forKey: .searchFolder) ?? defaults.searchFolder
        searchTimeout = try container.decodeIfPresent(Double.self, forKey: .searchTimeout) ?? defaults.searchTimeout
        excluded = try container.decodeIfPresent([String].self, forKey: .excluded) ?? defaults.excluded
    }
}
