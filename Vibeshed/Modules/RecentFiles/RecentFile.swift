import Foundation
import UniformTypeIdentifiers

/// A file in Finder's Recents: something opened through LaunchServices (Finder, the
/// `open` command, an app's Open dialog), as Spotlight's `kMDItemLastUsedDate` records it.
struct RecentFile: Sendable, Equatable {
    let path: String
    /// Spotlight's `kMDItemContentType`, when it has one.
    let contentType: String?
    let lastUsed: Date
    /// Spotlight's `kMDItemLogicalSize`, in bytes.
    let size: Int64?
    let name: String
    /// The parent folder as the picker shows it: `~/Downloads`, `iCloud Drive/Taxes`.
    let folder: String

    init(path: String, contentType: String?, lastUsed: Date, size: Int64? = nil, home: String = NSHomeDirectory()) {
        self.path = path
        self.contentType = contentType
        self.lastUsed = lastUsed
        self.size = size
        name = (path as NSString).lastPathComponent
        folder = RecentFilePaths.displayFolder(of: path, home: home)
    }

    /// Spotlight's type, else the one the file's extension names. Never read from the
    /// file: one in Desktop, Documents or Downloads would raise a privacy prompt.
    var type: UTType {
        contentType.flatMap { UTType($0) }
            ?? UTType(filenameExtension: (name as NSString).pathExtension)
            ?? .data
    }
}

/// Which of Spotlight's recently used files Finder's Recents shows, and how their folders read.
enum RecentFilePaths {
    /// Folders inside `~/Library` that hold the user's own files: iCloud Drive and the
    /// File Provider folders (Dropbox, Google Drive, OneDrive). Finder lists their files
    /// in Recents; on a Mac with Dropbox and iCloud Drive they were 70 of its 389.
    static let cloudFolders = ["Library/Mobile Documents/", "Library/CloudStorage/"]

    static let iCloudDrive = "Library/Mobile Documents/com~apple~CloudDocs"

    /// A user's file as Finder would list it: not in `~/Library` other than its cloud
    /// folders, not hidden (a path component starting with "."), and not inside a
    /// package (an app, a Photos library). Decided from the path alone.
    static func isListable(_ path: String, home: String) -> Bool {
        let components = path.split(separator: "/")
        guard !components.isEmpty, !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homePrefix + "Library/"),
           !cloudFolders.contains(where: { path.hasPrefix(homePrefix + $0) })
        {
            return false
        }
        return !components.dropLast().contains { isPackageName($0) }
    }

    /// A folder name whose extension makes it a package, judged by the extension's type.
    static func isPackageName(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty else { return false }
        // As a directory: an extension looked up as data (the default) names no bundle type.
        return UTType(filenameExtension: String(ext), conformingTo: .directory)?.conforms(to: .package) ?? false
    }

    /// `path`'s folder, shortened the way Finder names it: `~` for home, `iCloud Drive`
    /// for iCloud Drive and an app's iCloud folder, a File Provider folder by its own name.
    static func displayFolder(of path: String, home: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let homeDir = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard folder == homeDir || folder.hasPrefix(homeDir + "/") else { return folder }
        let relative = String(folder.dropFirst(homeDir.count)).drop { $0 == "/" }
        if relative == iCloudDrive || relative.hasPrefix(iCloudDrive + "/") {
            return "iCloud Drive" + relative.dropFirst(iCloudDrive.count)
        }
        if relative.hasPrefix(cloudFolders[0]) {
            // An app's container, `iCloud~com~apple~iBooks/Documents/…`: iCloud Drive
            // shows it as the app's folder.
            var parts = relative.dropFirst(cloudFolders[0].count).split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return "iCloud Drive" }
            let app = parts.removeFirst().split(separator: "~").last.map(String.init) ?? ""
            if parts.first == "Documents" {
                parts.removeFirst()
            }
            return (["iCloud Drive", app] + parts).joined(separator: "/")
        }
        if relative.hasPrefix(cloudFolders[1]) {
            let rest = relative.dropFirst(cloudFolders[1].count)
            return rest.isEmpty ? "~/" + relative : String(rest)
        }
        return relative.isEmpty ? "~" : "~/" + relative
    }
}

/// Recent files searched by the words of their names and folders.
struct RecentFilesIndex: Sendable {
    enum Mode {
        /// Each query word starts a word of the name or folder, as the picker's
        /// word-prefix gate checks for main-search rows.
        case wordPrefix
        /// Each query word appears anywhere in the name or folder (Search Recent Files).
        case anywhere
    }

    struct Match: Sendable {
        let file: RecentFile
        let rank: Double
        /// 1 just now, ½ a week ago, ⅓ two weeks ago.
        let recency: Double
    }

    static let empty = RecentFilesIndex(files: [])

    /// Most recently used first.
    let files: [RecentFile]
    /// Names and folders as `SearchWords` folds them: " q3 report pdf".
    private let names: [[UInt8]]
    private let folders: [[UInt8]]

    init(files: [RecentFile]) {
        self.files = files
        names = files.map { SearchWords.fold($0.name) }
        folders = files.map { SearchWords.fold($0.folder) }
    }

    var count: Int {
        files.count
    }

    var isEmpty: Bool {
        files.isEmpty
    }

    func contains(path: String) -> Bool {
        files.contains { $0.path == path }
    }

    /// The file with `StableID.hash(path)` == `hash`, for resolving a row's action ID
    /// (keybindings, aliases, URIs).
    func file(hash: String) -> RecentFile? {
        files.first { StableID.hash($0.path) == hash }
    }

    /// The best `limit` files for `query`, best first: a word starting the name before
    /// one starting the folder, before one inside either, with recently used files
    /// ahead of comparable matches. With nothing typed, the most recently used.
    func search(_ query: String, mode: Mode, limit: Int, now: Date = Date()) -> [Match] {
        guard limit > 0 else { return [] }
        let words = SearchWords.queryWords(query)
        guard !words.isEmpty else {
            return files.prefix(limit).map { Match(file: $0, rank: 0, recency: Self.recency(of: $0, now: now)) }
        }
        let starts = words.map { [SearchWords.space] + $0 }
        var ranked: [(rank: Double, recency: Double, file: Int)] = []
        for file in files.indices {
            var quality = 0.0
            var matchedAll = true
            for (word, start) in zip(words, starts) {
                guard let found = self.quality(of: word, start: start, in: file, mode: mode) else {
                    matchedAll = false
                    break
                }
                quality += found
            }
            guard matchedAll else { continue }
            let recency = Self.recency(of: files[file], now: now)
            ranked.append((quality / Double(words.count) + recency, recency, file))
        }
        // Stable for equal ranks: the more recently used file stays first.
        ranked.sort { $0.rank != $1.rank ? $0.rank > $1.rank : $0.file < $1.file }
        return ranked.prefix(limit).map { Match(file: files[$0.file], rank: $0.rank, recency: $0.recency) }
    }

    private func quality(of word: [UInt8], start: [UInt8], in file: Int, mode: Mode) -> Double? {
        if Self.contains(names[file], start) { return 1 }
        if Self.contains(folders[file], start) { return 0.5 }
        guard mode == .anywhere else { return nil }
        if Self.contains(names[file], word) { return 0.6 }
        if Self.contains(folders[file], word) { return 0.3 }
        return nil
    }

    static func recency(of file: RecentFile, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(file.lastUsed)) / 86400
        return 1 / (1 + days / 7)
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                guard let hayBase = hay.baseAddress, let pinBase = pin.baseAddress else { return false }
                return memmem(hayBase, hay.count, pinBase, pin.count) != nil
            }
        }
    }
}
