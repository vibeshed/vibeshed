import Foundation
import SQLite3
@testable import Vibeshed
import XCTest

/// Codex threads as Codex Desktop lists them, from its catalog in
/// `~/.codex/sqlite/codex.db`: threads on SSH hosts, current titles and times, and
/// none of the helper threads the app hides. The session files stand in without it.
final class CodexThreadCatalogTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sqlite"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Catalog

    /// A thread on an SSH host has no transcript on this Mac; the catalog alone lists
    /// it. ChatGPT chats and threads the app lost track of stay out.
    func testListsLocalAndSSHThreadsNewestFirst() throws {
        try makeCatalog([
            row("local-1", "Debug stalled deploys", minutesAgo: 20, cwd: "/Users/me/infra", branch: "chore/logs"),
            row(
                "remote-1",
                "Personal agent from scratch",
                minutesAgo: 5,
                cwd: "/home/me/agent",
                host: "remote-ssh-discovered:geek"
            ),
            row("chat-1", "USB speaker", minutesAgo: 1, kind: "chatgpt", host: "chatgpt:acct:user"),
            row("lost-1", "Gone", minutesAgo: 2, missing: true),
        ])

        let sessions = OpenAISessionReader.readSessions(limit: 10, root: root)
        XCTAssertEqual(sessions.map(\.title), ["Personal agent from scratch", "Debug stalled deploys"])

        let remote = try XCTUnwrap(sessions.first)
        XCTAssertEqual(remote.host, AISessionHost(id: "remote-ssh-discovered:geek", name: "geek"))
        XCTAssertEqual(remote.project, "/home/me/agent")
        XCTAssertEqual(remote.projectLabel, "geek:/home/me/agent")
        XCTAssertEqual(remote.timestamp.timeIntervalSince1970, now.timeIntervalSince1970 - 300, accuracy: 0.01)

        let local = try XCTUnwrap(sessions.last)
        XCTAssertNil(local.host)
        XCTAssertEqual(local.branch, "chore/logs")
    }

    /// `session_index.jsonl` keeps a thread's first title and time, and lists the
    /// automatic-review threads the app hides. The catalog decides instead, and the
    /// transcript still gives the model.
    func testCatalogOverridesTheStaleIndexAndHidesHelperThreads() throws {
        let thread = "01a1b121-895e-74b2-8a65-c0057a292a52"
        let review = "01a1ef53-a37e-79d0-82fa-6a843c4e9c1a"
        try writeIndex([
            (thread, "Old title", "2026-11-06T13:53:27.051211Z"),
            (review, "Guardian review", iso(minutesAgo: 1)),
        ])
        try writeTranscript(thread, model: "gpt-5.5-codex")
        try writeTranscript(review, model: "codex-auto-review")
        try makeCatalog([row(thread, "Debug stalled deploys", minutesAgo: 3)])

        let sessions = OpenAISessionReader.readSessions(limit: 10, root: root)
        XCTAssertEqual(sessions.map(\.sessionID), [thread])
        XCTAssertEqual(sessions.first?.title, "Debug stalled deploys")
        XCTAssertEqual(
            sessions.first?.timestamp.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 - 180, accuracy: 0.01
        )
        XCTAssertNotNil(sessions.first?.model)
    }

    func testWithoutACatalogTheSessionFilesDecide() throws {
        try writeIndex([("01a1b121-895e-74b2-8a65-c0057a292a52", "From the index", iso(minutesAgo: 1))])
        let sessions = OpenAISessionReader.readSessions(limit: 10, root: root)
        XCTAssertEqual(sessions.map(\.title), ["From the index"])
        XCTAssertNil(sessions.first?.host)
    }

    /// A schema this doesn't know reads as no catalog rather than as no threads.
    func testUnknownCatalogSchemaFallsBackToTheSessionFiles() throws {
        try writeIndex([("01a1b121-895e-74b2-8a65-c0057a292a52", "From the index", iso(minutesAgo: 1))])
        try makeCatalog([], schema: "CREATE TABLE local_thread_catalog (thread_id TEXT, title TEXT)")
        XCTAssertNil(CodexThreadCatalog.threads(databasePath: catalogPath, limit: 10))
        XCTAssertEqual(OpenAISessionReader.readSessions(limit: 10, root: root).map(\.title), ["From the index"])
    }

    func testStopsAtTheLimit() throws {
        try makeCatalog((1 ... 5).map { row("t\($0)", "Thread \($0)", minutesAgo: Double($0)) })
        XCTAssertEqual(OpenAISessionReader.readSessions(limit: 2, root: root).map(\.title), ["Thread 1", "Thread 2"])
    }

    // MARK: - Hosts and links

    func testHostIDs() {
        XCTAssertNil(CodexThreadCatalog.host(id: "local"))
        XCTAssertEqual(
            CodexThreadCatalog.host(id: "remote-ssh-discovered:geek"),
            AISessionHost(id: "remote-ssh-discovered:geek", name: "geek")
        )
    }

    /// The app opens a thread on another machine only with that machine's `hostId`.
    func testThreadOnAnotherHostLinksWithItsHostID() throws {
        let link = OpenAIDeeplink.thread("01a1edb3-f1a9-7b82-bec8-bf4e4351c875", hostID: "remote-ssh-discovered:geek")
        let components = try XCTUnwrap(URLComponents(string: link))
        XCTAssertEqual(components.scheme, "codex")
        XCTAssertEqual(components.host, "threads")
        XCTAssertEqual(components.path, "/01a1edb3-f1a9-7b82-bec8-bf4e4351c875")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "hostId", value: "remote-ssh-discovered:geek")])
    }

    func testRemoteSessionRowNamesTheHost() {
        let session = AISession(
            sessionID: "remote-1", source: OpenAIProvider.codex, title: "Personal agent",
            project: FileManager.default.homeDirectoryForCurrentUser.path + "/agent",
            timestamp: now, host: AISessionHost(id: "remote-ssh-discovered:geek", name: "geek")
        )
        let row = AIAction.forSession(
            session, module: OpenAIProvider.identity, namePrefix: "session", relevanceScore: 0.5
        ) {}
        // The path is on geek, so this Mac's home must not turn into `~`.
        XCTAssertTrue(row.subtitle.contains("geek:\(FileManager.default.homeDirectoryForCurrentUser.path)/agent"))
        XCTAssertTrue(row.keywords.contains("geek"))
    }

    // MARK: - Helpers

    private var catalogPath: String {
        CodexThreadCatalog.databasePath(root: root)
    }

    private static let schema = """
    CREATE TABLE local_thread_catalog (
        host_id TEXT NOT NULL, thread_id TEXT NOT NULL, display_title TEXT NOT NULL,
        source_created_at REAL NOT NULL, source_updated_at REAL NOT NULL, cwd TEXT,
        source_kind TEXT NOT NULL, git_branch TEXT, missing_candidate INTEGER NOT NULL DEFAULT 0,
        thread_source TEXT, source_recency_at REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (host_id, thread_id)
    )
    """

    private func row(
        _ id: String,
        _ title: String,
        minutesAgo: Double,
        cwd: String? = nil,
        branch: String? = nil,
        kind: String = "vscode",
        host: String = "local",
        missing: Bool = false
    ) -> String {
        let updated = now.timeIntervalSince1970 - minutesAgo * 60
        let values = [
            "'\(host)'", "'\(id)'", "'\(title)'", "\(updated - 600)", "\(updated)",
            cwd.map { "'\($0)'" } ?? "NULL", "'\(kind)'", branch.map { "'\($0)'" } ?? "NULL",
            missing ? "1" : "0", "'user'", "\(updated)",
        ]
        return "INSERT INTO local_thread_catalog VALUES (\(values.joined(separator: ", ")))"
    }

    private func makeCatalog(_ inserts: [String], schema: String = CodexThreadCatalogTests.schema) throws {
        var db: OpaquePointer?
        guard sqlite3_open(catalogPath, &db) == SQLITE_OK, let db else {
            return XCTFail("cannot create \(catalogPath)")
        }
        defer { sqlite3_close(db) }
        for sql in [schema] + inserts {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                return XCTFail("\(String(cString: sqlite3_errmsg(db))): \(sql)")
            }
        }
    }

    private func iso(minutesAgo: Double) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now.addingTimeInterval(-minutesAgo * 60))
    }

    private func writeIndex(_ entries: [(id: String, title: String, updated: String)]) throws {
        var index = Data()
        for entry in entries {
            let json: [String: Any] = ["id": entry.id, "thread_name": entry.title, "updated_at": entry.updated]
            index += try JSONSerialization.data(withJSONObject: json) + Data("\n".utf8)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
    }

    /// A transcript with its header and one turn on `model`.
    private func writeTranscript(_ id: String, model: String) throws {
        let day = root.appendingPathComponent("sessions/2026/11/18")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/Users/me/infra"]],
            ["type": "turn_context", "payload": ["model": model]],
        ]
        var transcript = Data()
        for record in records {
            transcript += try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8)
        }
        try transcript.write(to: day.appendingPathComponent("rollout-2026-11-18T19-43-18-\(id).jsonl"))
    }
}
