import Foundation
import OSLog
import SQLite3

private let log = Log.module("openai")

/// Codex Desktop's own list of threads, the `local_thread_catalog` table of
/// `~/.codex/sqlite/codex.db`. It is what the app's sidebar shows, so it has what the
/// session files lack: current titles and update times (`session_index.jsonl` keeps a
/// thread's first ones), threads on SSH hosts (whose transcripts stay on the host), and
/// none of the helper threads the app hides, like its automatic reviews
/// (`thread_source: guardian_review`). Undocumented; this follows Codex 26.1111.
enum CodexThreadCatalog {
    struct Thread: Equatable {
        let id: String
        let title: String?
        let updatedAt: Date
        let cwd: String?
        let branch: String?
        /// Nil for a thread on this Mac.
        let host: AISessionHost?
    }

    static func databasePath(root: URL) -> String {
        root.appendingPathComponent("sqlite/codex.db").path
    }

    /// The `limit` most recently updated threads, newest first. Nil when there is no
    /// catalog to read (Codex Desktop never ran, or a schema this doesn't know), so the
    /// caller falls back to the session files.
    static func threads(databasePath: String, limit: Int) -> [Thread]? {
        guard FileManager.default.fileExists(atPath: databasePath), let db = open(databasePath) else {
            return nil
        }
        defer { sqlite3_close(db) }
        guard let sql = query(in: db) else {
            log.error("Codex thread catalog has no readable thread table")
            return nil
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            log.error("Codex catalog query failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(clamping: limit))

        var threads: [Thread] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0), !id.isEmpty else { continue }
            threads.append(Thread(
                id: id,
                title: text(stmt, 1)?.asSessionTitle(),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                cwd: text(stmt, 3).flatMap { $0.isEmpty ? nil : $0 },
                branch: text(stmt, 4).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 },
                host: text(stmt, 5).flatMap(host(id:))
            ))
        }
        return threads
    }

    /// `local` is this Mac. Other hosts are `<kind>:<name>`, e.g.
    /// `remote-ssh-discovered:geek` for the SSH host `geek`.
    static func host(id: String) -> AISessionHost? {
        guard id != "local" else { return nil }
        let name = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
        return AISessionHost(id: id, name: name)
    }

    // MARK: - Database

    /// Selects id, title, update time (seconds since 1970), cwd, branch and host, with
    /// `?1` as the row limit. ChatGPT conversations, which the app lists too, are chats
    /// rather than Codex threads; `missing_candidate` rows are threads it lost track of.
    private static func query(in db: OpaquePointer) -> String? {
        let columns = columnNames(of: "local_thread_catalog", in: db)
        let required: Set = ["thread_id", "display_title", "source_updated_at", "host_id"]
        guard required.isSubset(of: columns) else { return nil }
        var filters = ["host_id NOT LIKE 'chatgpt:%'"]
        if columns.contains("source_kind") {
            filters.append("source_kind <> 'chatgpt'")
        }
        if columns.contains("missing_candidate") {
            filters.append("missing_candidate = 0")
        }
        let cwd = columns.contains("cwd") ? "cwd" : "NULL"
        let branch = columns.contains("git_branch") ? "git_branch" : "NULL"
        return """
        SELECT thread_id, display_title, source_updated_at, \(cwd), \(branch), host_id \
        FROM local_thread_catalog WHERE \(filters.joined(separator: " AND ")) \
        ORDER BY source_updated_at DESC LIMIT ?1
        """
    }

    /// Read-only without `immutable`, so threads still in the write-ahead log the app
    /// keeps open are seen too.
    private static func open(_ path: String) -> OpaquePointer? {
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            log.error("Cannot open the Codex thread catalog at \(path, privacy: .public)")
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 250)
        return db
    }

    private static func columnNames(of table: String, in db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: name))
            }
        }
        return names
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
}
