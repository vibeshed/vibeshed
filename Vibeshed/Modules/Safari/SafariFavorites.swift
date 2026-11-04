import Foundation

/// A bookmark in Safari's Favorites.
struct SafariFavorite: Sendable, Equatable {
    let title: String
    let url: String
    /// The folders inside Favorites that hold it, outermost first; empty at the top.
    let folders: [String]

    var displayTitle: String {
        title.isEmpty ? SafariURL.display(url) : title
    }
}

enum SafariFavoritesReader {
    /// Safari's name for the Favorites list in Bookmarks.plist.
    static let favoritesListTitle = "BookmarksBar"

    /// The bookmarks in Favorites, in Safari's order. No Bookmarks.plist (Safari never
    /// ran) is no favorites; one that can't be read is an error.
    static func read(at path: String) throws -> [SafariFavorite] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SafariReadError.unreadable("Bookmarks.plist")
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return favorites(in: plist as? [String: Any] ?? [:])
    }

    static func favorites(in root: [String: Any]) -> [SafariFavorite] {
        let lists = root["Children"] as? [[String: Any]] ?? []
        guard let favorites = lists.first(where: { $0["Title"] as? String == favoritesListTitle }) else { return [] }
        var found: [SafariFavorite] = []
        collect(favorites, folders: [], into: &found)
        // A page saved twice is one row, where it comes first.
        var seen: Set<String> = []
        return found.filter { seen.insert($0.url).inserted }
    }

    private static func collect(_ node: [String: Any], folders: [String], into found: inout [SafariFavorite]) {
        for child in node["Children"] as? [[String: Any]] ?? [] {
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = child["URLString"] as? String, SafariURL.isListable(url) else { continue }
                let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                found.append(SafariFavorite(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url,
                    folders: folders
                ))
            case "WebBookmarkTypeList":
                collect(child, folders: folders + [child["Title"] as? String ?? ""], into: &found)
            default:
                continue
            }
        }
    }
}
