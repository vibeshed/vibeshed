import SQLite3
@testable import Vibeshed
import XCTest

/// Safari's files, written the way Safari 27 lays them out (columns from a real
/// History.db and CloudTabs.db), in a scratch home.
final class SafariFixture {
    let home: URL
    var files: SafariFiles {
        SafariFiles(home: home.path)
    }

    /// Writers left open so their write-ahead logs aren't checkpointed, as while Safari runs.
    private var openDatabases: [OpaquePointer] = []

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("safari-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari"),
            withIntermediateDirectories: true
        )
    }

    deinit {
        openDatabases.forEach { sqlite3_close($0) }
        try? FileManager.default.removeItem(at: home)
    }

    static let historySchema = [
        """
        CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL UNIQUE,
        domain_expansion TEXT NULL,visit_count INTEGER NOT NULL,daily_visit_counts BLOB NOT NULL DEFAULT x'',
        weekly_visit_counts BLOB NULL,autocomplete_triggers BLOB NULL,
        should_recompute_derived_visit_counts INTEGER NOT NULL DEFAULT 0,visit_count_score INTEGER NOT NULL,
        status_code INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,history_item INTEGER NOT NULL
        REFERENCES history_items(id) ON DELETE CASCADE,visit_time REAL NOT NULL,title TEXT NULL,
        load_successful BOOLEAN NOT NULL DEFAULT 1,http_non_get BOOLEAN NOT NULL DEFAULT 0,
        synthesized BOOLEAN NOT NULL DEFAULT 0,redirect_source INTEGER NULL UNIQUE,
        redirect_destination INTEGER NULL UNIQUE,origin INTEGER NOT NULL DEFAULT 0,
        generation INTEGER NOT NULL DEFAULT 0,attributes INTEGER NOT NULL DEFAULT 0,score INTEGER NOT NULL DEFAULT 0)
        """,
    ]

    struct Visit {
        var ago: TimeInterval
        var title: String?
        var loaded = true
        var redirected = false
    }

    struct Page {
        var url: String
        var visitCount = 1
        var score = 100
        var visits: [Visit]
    }

    /// Writes History.db in WAL mode and keeps the writer open, so every row is still in
    /// the write-ahead log when the module reads it.
    func writeHistory(_ pages: [Page], now: Date) throws {
        let db = try Self.open(files.history)
        openDatabases.append(db)
        try Self.exec(db, "PRAGMA journal_mode=WAL")
        try Self.exec(db, "PRAGMA wal_autocheckpoint=0")
        try Self.historySchema.forEach { try Self.exec(db, $0) }
        var redirectTarget = 1000
        for (index, page) in pages.enumerated() {
            let item = index + 1
            try Self.exec(
                db,
                "INSERT INTO history_items (id, url, visit_count, visit_count_score) "
                    + "VALUES (\(item), '\(page.url)', \(page.visitCount), \(page.score))"
            )
            for visit in page.visits {
                let time = now.addingTimeInterval(-visit.ago).timeIntervalSinceReferenceDate
                let title = visit.title.map { "'\($0)'" } ?? "NULL"
                redirectTarget += 1
                let destination = visit.redirected ? "\(redirectTarget)" : "NULL"
                try Self.exec(
                    db,
                    "INSERT INTO history_visits (history_item, visit_time, title, load_successful, "
                        + "redirect_destination) VALUES (\(item), \(time), \(title), \(visit.loaded ? 1 : 0), "
                        + "\(destination))"
                )
            }
        }
    }

    struct Tab {
        var device: String
        var url: String
        var title: String?
        var viewedAgo: TimeInterval
        var pinned = false
    }

    func writeCloudTabs(
        devices: [(id: String, name: String, type: String)],
        tabs: [Tab],
        now: Date,
        withViewTimes: Bool = true
    ) throws {
        let db = try Self.open(files.cloudTabCandidates[0])
        defer { sqlite3_close(db) }
        try Self.exec(
            db,
            """
            CREATE TABLE cloud_tab_devices (device_uuid TEXT PRIMARY KEY NOT NULL,
            system_fields BLOB NOT NULL DEFAULT x'',device_name TEXT,device_type_identifier TEXT,
            has_duplicate_device_name BOOLEAN DEFAULT 0,
            is_ephemeral_device BOOLEAN DEFAULT 0,last_modified REAL NOT NULL DEFAULT 0)
            """
        )
        try Self.exec(
            db,
            """
            CREATE TABLE cloud_tabs (tab_uuid TEXT PRIMARY KEY NOT NULL,system_fields BLOB NOT NULL DEFAULT x'',
            device_uuid TEXT NOT NULL,position BLOB NOT NULL DEFAULT x'',title TEXT,url TEXT NOT NULL,
            is_showing_reader BOOLEAN DEFAULT 0,is_pinned BOOLEAN DEFAULT 0,reader_scroll_position_page_index INTEGER,
            scene_id TEXT\(withViewTimes ? ",last_viewed_time REAL DEFAULT 0" : ""),topic_title TEXT)
            """
        )
        for device in devices {
            try Self.exec(
                db,
                "INSERT INTO cloud_tab_devices (device_uuid, device_name, device_type_identifier) "
                    + "VALUES ('\(device.id)', '\(device.name)', '\(device.type)')"
            )
        }
        for tab in tabs {
            let title = tab.title.map { "'\($0)'" } ?? "NULL"
            let viewed = now.addingTimeInterval(-tab.viewedAgo).timeIntervalSinceReferenceDate
            let viewColumn = withViewTimes ? ", last_viewed_time" : ""
            let viewValue = withViewTimes ? ", \(viewed)" : ""
            try Self.exec(
                db,
                "INSERT INTO cloud_tabs (tab_uuid, device_uuid, title, url, is_pinned\(viewColumn)) "
                    + "VALUES ('\(UUID().uuidString)', '\(tab.device)', \(title), '\(tab.url)', "
                    + "\(tab.pinned ? 1 : 0)\(viewValue))"
            )
        }
    }

    static func leaf(_ title: String, _ url: String) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title]]
    }

    static func list(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children]
    }

    static var bookmarks: [String: Any] {
        [
        "WebBookmarkType": "WebBookmarkTypeList",
        "Title": "",
        "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            list("BookmarksBar", [
                leaf("Vibeshed", "https://vibeshed.dev/"),
                list("Dev", [
                    leaf("Swift Forums", "https://forums.swift.org/"),
                    leaf("Bookmarklet", "javascript:alert(1)"),
                ]),
                leaf("Vibeshed again", "https://vibeshed.dev/"),
            ]),
            list("BookmarksMenu", [leaf("Menu Only", "https://menu.example/")]),
            list("com.apple.ReadingList", [leaf("To Read", "https://read.example/")]),
        ],
        ]
    }

    func writeBookmarks(_ root: [String: Any] = SafariFixture.bookmarks) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: files.bookmarks))
    }

    static func open(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw FixtureError("cannot open \(path)") }
        return db
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError("\(String(cString: sqlite3_errmsg(db))): \(sql)")
        }
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}

extension SafariFixture {
    /// One more page, through a second connection, as Safari adds a visit while it runs.
    func writeHistoryVisit(url: String, title: String, now: Date) throws {
        let db = try Self.open(files.history)
        defer { sqlite3_close(db) }
        try Self.exec(db, "INSERT INTO history_items (url, visit_count, visit_count_score) VALUES ('\(url)', 1, 20)")
        try Self.exec(
            db,
            "INSERT INTO history_visits (history_item, visit_time, title) "
                + "VALUES (last_insert_rowid(), \(now.timeIntervalSinceReferenceDate), '\(title)')"
        )
    }
}

extension SafariFixture {
    /// A new title for a page's visits, through a second connection, as Safari updates a
    /// page it already listed.
    func retitle(url: String, to title: String) throws {
        let db = try Self.open(files.history)
        defer { sqlite3_close(db) }
        try Self.exec(
            db,
            "UPDATE history_visits SET title = '\(title)' "
                + "WHERE history_item = (SELECT id FROM history_items WHERE url = '\(url)')"
        )
    }
}

/// Counts from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func add() {
        lock.withLock { count += 1 }
    }
}

/// URLs a test's module opened.
final class OpenedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [String] = []

    var urls: [String] {
        lock.withLock { opened }
    }

    func append(_ url: URL) {
        lock.withLock { opened.append(url.absoluteString) }
    }
}
