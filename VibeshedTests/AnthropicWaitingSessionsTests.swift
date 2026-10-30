import Foundation
@testable import Vibeshed
import XCTest

/// Which Claude sessions count as waiting on the user, read from the records running
/// Claude Code processes keep in `~/.claude/sessions`, and how that reaches the rows.
final class AnthropicWaitingSessionsTests: XCTestCase {
    private var root: URL!

    private var records: URL {
        root.appendingPathComponent("sessions")
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waiting-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Live records

    func testWaitingSessionIsKeyedByItsCLIAndDesktopIDs() throws {
        try writeRecord(session: "cli-1", status: "waiting", waitingFor: "permission prompt", host: "local_1")
        XCTAssertEqual(
            AnthropicLiveSessions.waiting(in: records),
            ["cli-1": "permission prompt", "local_1": "permission prompt"]
        )
    }

    func testBusyAndIdleSessionsAreNotWaiting() throws {
        try writeRecord(session: "busy", status: "busy")
        try writeRecord(session: "idle", status: "idle")
        XCTAssertEqual(AnthropicLiveSessions.waiting(in: records), [:])
    }

    func testWaitingWithoutAReasonStillCounts() throws {
        try writeRecord(session: "cli-1", status: "waiting")
        XCTAssertEqual(AnthropicLiveSessions.waiting(in: records), ["cli-1": "input"])
    }

    /// A process killed mid-prompt leaves its record behind.
    func testRecordOfAnExitedProcessIsIgnored() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try writeRecord(session: "gone", status: "waiting", pid: process.processIdentifier)
        XCTAssertEqual(AnthropicLiveSessions.waiting(in: records), [:])
    }

    /// The record predates the process holding its pid now, so that pid was reused.
    func testRecordOlderThanItsProcessIsIgnored() throws {
        let started = try XCTUnwrap(ProcessSnapshot(pid: ownPID)?.startTime)
        try writeRecord(session: "stale", status: "waiting", startedAt: started.addingTimeInterval(-3600))
        XCTAssertEqual(AnthropicLiveSessions.waiting(in: records), [:])
    }

    func testRecordFromAnotherPIDDomainIsIgnored() throws {
        try writeRecord(session: "vm", status: "waiting", extra: ["pidDomain": "linux"])
        XCTAssertEqual(AnthropicLiveSessions.waiting(in: records), [:])
    }

    // MARK: - Running sessions

    func testRunningFindsTheSessionWhateverItsStatus() throws {
        try writeRecord(session: "cli-1", status: "idle")
        try writeRecord(session: "cli-2", status: "busy")
        XCTAssertEqual(AnthropicLiveSessions.running("cli-1", in: records)?.pid, ownPID)
        XCTAssertNil(AnthropicLiveSessions.running("cli-3", in: records))
    }

    /// Resuming a session that is already open leaves two processes holding it.
    func testRunningPrefersTheRecordWrittenLast() throws {
        try writeRecord(session: "cli-1", status: "idle", host: "local_old", extra: ["updatedAt": 1000], file: "a")
        try writeRecord(session: "cli-1", status: "busy", host: "local_new", extra: ["updatedAt": 2000], file: "b")
        XCTAssertEqual(AnthropicLiveSessions.running("cli-1", in: records)?.hostSessionID, "local_new")
    }

    // MARK: - Session list

    /// The waiting session is the oldest of three, yet it survives a cap of two and
    /// leads the list.
    func testWaitingCLISessionLeadsAndSurvivesTheCap() throws {
        let now = Date().timeIntervalSince1970 * 1000
        try writeHistory([
            ("waiting-cli", "fix the flaky test", now - 3_600_000),
            ("older-cli", "write the changelog", now - 60000),
            ("newest-cli", "bump the version", now),
        ])
        try writeRecord(session: "waiting-cli", status: "waiting", waitingFor: "input needed")

        let sessions = readSessions(limit: 2)
        XCTAssertEqual(sessions.map(\.sessionID), ["waiting-cli", "newest-cli"])
        XCTAssertEqual(sessions.first?.waitingFor, "input needed")
        XCTAssertNil(sessions.last?.waitingFor)
    }

    /// Claude Desktop runs its sessions on the CLI, which names the desktop session
    /// in `hostSessionId`.
    func testDesktopSessionIsMarkedThroughItsHostID() throws {
        let session = root.appendingPathComponent("desktop/account/workspace")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "sessionId": "local_1", "cliSessionId": "desktop-cli", "title": "Ship it",
            "lastActivityAt": Date().timeIntervalSince1970 * 1000,
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: session.appendingPathComponent("local_1.json"))
        try writeRecord(session: "desktop-cli", status: "waiting", waitingFor: "permission prompt", host: "local_1")

        let sessions = readSessions(limit: 10)
        XCTAssertEqual(sessions.map(\.sessionID), ["local_1"])
        XCTAssertEqual(sessions.first?.waitingFor, "permission prompt")
    }

    // MARK: - Rows

    func testWaitingSessionRowAwaitsTheUser() {
        let waiting = row(for: AISession(
            sessionID: "s", source: AnthropicProvider.claudeCode, title: "Fix it",
            timestamp: Date(), waitingFor: "permission prompt"
        ))
        XCTAssertTrue(waiting.isAwaitingUser)
        XCTAssertTrue(waiting.keywords.contains("waiting"))

        let idle = row(for: AISession(
            sessionID: "s", source: AnthropicProvider.claudeCode, title: "Fix it", timestamp: Date()
        ))
        XCTAssertFalse(idle.isAwaitingUser)
        XCTAssertFalse(idle.keywords.contains("waiting"))
    }

    // MARK: - Helpers

    /// A record as Claude Code writes it, for this test process unless `pid` says otherwise.
    private func writeRecord(
        session: String,
        status: String,
        waitingFor: String? = nil,
        host: String? = nil,
        pid: pid_t? = nil,
        startedAt: Date = Date(),
        extra: [String: Any] = [:],
        file: String? = nil
    ) throws {
        let pid = pid ?? ownPID
        var json: [String: Any] = [
            "pid": Int(pid), "sessionId": session, "status": status, "kind": "interactive",
            "pidDomain": "darwin", "startedAt": (startedAt.timeIntervalSince1970 * 1000).rounded(),
        ]
        json["waitingFor"] = waitingFor
        json["hostSessionId"] = host
        json.merge(extra) { $1 }
        try JSONSerialization.data(withJSONObject: json)
            .write(to: records.appendingPathComponent("\(file ?? "\(pid)-\(session)").json"))
    }

    private func writeHistory(_ entries: [(session: String, prompt: String, at: Double)]) throws {
        var history = Data()
        for entry in entries {
            let json: [String: Any] = [
                "display": entry.prompt, "timestamp": entry.at, "project": "/tmp/project",
                "sessionId": entry.session,
            ]
            history += try JSONSerialization.data(withJSONObject: json) + Data("\n".utf8)
        }
        try history.write(to: root.appendingPathComponent("history.jsonl"))
    }

    private func readSessions(limit: Int) -> [AISession] {
        AnthropicSessionReader.readSessions(
            sources: ["claudeCode", "claudeDesktop"],
            limit: limit,
            locations: AnthropicSessionReader.Locations(
                claudeDirectory: root,
                desktopSessionsDirectory: root.appendingPathComponent("desktop")
            )
        )
    }

    private func row(for session: AISession) -> AIAction {
        AIAction.forSession(
            session, module: AnthropicProvider.identity, namePrefix: "session", relevanceScore: 0.9
        ) {}
    }
}
