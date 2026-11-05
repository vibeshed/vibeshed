import Foundation

struct RecentFilesConfig: Codable, Sendable, Equatable {
    /// Recent files listed in the main search for a query of three or more letters whose
    /// words start words of the file's name or folder; 0 lists none. Search Recent Files
    /// always covers every file.
    var fileResults = 8

    /// Folders whose files, and their subfolders' files, are left out: `~/Downloads`.
    var excludedFolders: [String] = []

    /// Action name suffixes to expose (nil = all): `searchFiles`, or the row family `file`.
    var enabledActions: Set<String>?

    init() {}

    /// Decodes each field leniently: Codable synthesis ignores Swift property
    /// defaults, and a user's section may specify only some keys.
    init(from decoder: Decoder) throws {
        let defaults = RecentFilesConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileResults = try container.decodeIfPresent(Int.self, forKey: .fileResults) ?? defaults.fileResults
        excludedFolders = try container.decodeIfPresent([String].self, forKey: .excludedFolders)
            ?? defaults.excludedFolders
        enabledActions = try container.decodeIfPresent(Set<String>.self, forKey: .enabledActions)
    }

    private enum CodingKeys: String, CodingKey {
        case fileResults
        case excludedFolders
        case enabledActions
    }

    /// `excludedFolders` as absolute paths ending in "/", for prefix checks.
    func excludedPrefixes(home: String = NSHomeDirectory()) -> [String] {
        excludedFolders.compactMap { folder in
            let trimmed = folder.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            var path = trimmed == "~" || trimmed.hasPrefix("~/") ? home + trimmed.dropFirst() : trimmed
            path = (path as NSString).standardizingPath
            return path.hasSuffix("/") ? path : path + "/"
        }
    }
}
