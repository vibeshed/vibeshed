import Foundation
import SQLite3

/// Where Safari keeps what the module reads. Every one of these sits behind Full Disk Access.
struct SafariFiles: Sendable, Equatable {
    let history: String
    let bookmarks: String
    /// CloudTabs.db, first one that exists: Safari 17 and later keep it in their container.
    let cloudTabCandidates: [String]

    init(home: String = NSHomeDirectory()) {
        let library = home + "/Library/Safari"
        history = library + "/History.db"
        bookmarks = library + "/Bookmarks.plist"
        cloudTabCandidates = [
            home + "/Library/Containers/com.apple.Safari/Data/Library/Safari/CloudTabs.db",
            library + "/CloudTabs.db",
        ]
    }

    var cloudTabs: String {
        cloudTabCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? cloudTabCandidates[0]
    }
}

/// Modification date and size of a file, and of its SQLite write-ahead log for a
/// database: what changes when Safari writes, found without opening anything.
struct FileSignature: Equatable, Sendable {
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int
    }

    private let stamps: [Stamp?]

    init(_ path: String, database: Bool = false) {
        let paths = database ? [path, path + "-wal"] : [path]
        stamps = paths.map { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            return Stamp(
                modified: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    var exists: Bool {
        stamps.first.map { $0 != nil } ?? false
    }
}

enum SafariReadError: LocalizedError, Equatable {
    case cannotOpen(String)
    case query(String, String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(file):
            "Couldn't open \(file). Vibeshed needs Full Disk Access to read Safari's data."
        case let .query(file, message):
            "Couldn't read \(file): \(message)"
        case let .unreadable(file):
            "Couldn't read \(file). Vibeshed needs Full Disk Access to read Safari's data."
        }
    }
}

/// Read-only queries against Safari's SQLite databases while Safari has them open.
enum SafariDatabase {
    /// Runs `sql` and maps each row, skipping rows `map` returns nil for.
    static func rows<Row>(_ path: String, sql: String, map: (OpaquePointer) -> Row?) throws -> [Row] {
        try reduce(path, sql: sql, into: [Row]()) { rows, stmt in
            if let row = map(stmt) {
                rows.append(row)
            }
        }
    }

    /// Runs `sql`, folding every row into `initial`.
    ///
    /// Opened `mode=ro`, a connection reads the write-ahead log Safari hasn't
    /// checkpointed yet, which holds the latest visits. `immutable=1` skips the log, so
    /// it's only the fallback for when the log can't be used (no `-shm` to share); that
    /// attempt starts over from `initial`.
    static func reduce<State>(
        _ path: String,
        sql: String,
        into initial: State,
        _ step: (inout State, OpaquePointer) -> Void
    ) throws -> State {
        do {
            return try run(path, parameters: "mode=ro", sql: sql, into: initial, step)
        } catch {
            guard let state = try? run(path, parameters: "immutable=1", sql: sql, into: initial, step) else {
                throw error
            }
            return state
        }
    }

    private static func run<State>(
        _ path: String,
        parameters: String,
        sql: String,
        into initial: State,
        _ step: (inout State, OpaquePointer) -> Void
    ) throws -> State {
        let name = (path as NSString).lastPathComponent
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2("file:\(escaped)?\(parameters)", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            == SQLITE_OK
        else {
            throw SafariReadError.cannotOpen(name)
        }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SafariReadError.query(name, String(cString: sqlite3_errmsg(db)))
        }
        var state = initial
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            step(&state, stmt)
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else {
            throw SafariReadError.query(name, String(cString: sqlite3_errmsg(db)))
        }
        return state
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    /// A Core Data timestamp (seconds since 2001), nil when unset.
    static func date(_ stmt: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        let seconds = sqlite3_column_double(stmt, column)
        return seconds > 0 ? Date(timeIntervalSinceReferenceDate: seconds) : nil
    }
}

/// Pieces of a page's address for display and search, taken from the string itself:
/// `URL(string:)` would cost more than the rest of a history load.
enum SafariURL {
    /// "https://www.github.com/a/b?c#d" → ("www.github.com", "/a/b"): no query or fragment,
    /// which are rarely what anyone types (a search page's query is in its title anyway).
    /// Without "://" it's all path.
    static func split(_ url: String) -> (host: Substring, path: Substring) {
        var rest = url[...]
        var host = rest.prefix(0)
        if let scheme = url.range(of: "://") {
            rest = url[scheme.upperBound...]
            let hostEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
            host = rest[..<hostEnd]
            rest = rest[hostEnd...]
        }
        let pathEnd = rest.firstIndex { $0 == "?" || $0 == "#" } ?? rest.endIndex
        return (host, rest[..<pathEnd])
    }

    static func host(_ url: String) -> String {
        String(split(url).host)
    }

    /// Host and path, without "www.", query, fragment or trailing slash, to tell pages
    /// of one site apart: "github.com/vibeshed/vibeshed/pull/99".
    static func address(_ url: String) -> String {
        let (host, path) = split(url)
        var address = (host.hasPrefix("www.") ? host.dropFirst(4) : host) + path
        while address.hasSuffix("/") {
            address.removeLast()
        }
        return address.isEmpty ? display(url) : String(address)
    }

    /// The address as a title for a page without one: no scheme, no "www.", no trailing slash.
    static func display(_ url: String) -> String {
        var shown = Substring(url)
        if let scheme = shown.range(of: "://") {
            shown = shown[scheme.upperBound...]
        }
        if shown.hasPrefix("www.") {
            shown = shown.dropFirst(4)
        }
        while shown.hasSuffix("/") {
            shown = shown.dropLast()
        }
        return shown.isEmpty ? url : String(shown)
    }

    /// Schemes worth listing: Safari's history also holds `about:` and `data:` pages, and
    /// Favorites can hold `javascript:` bookmarklets, which only run inside a page.
    static func isListable(_ url: String) -> Bool {
        let lowered = url.prefix(8).lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://") || lowered.hasPrefix("file://")
    }
}
