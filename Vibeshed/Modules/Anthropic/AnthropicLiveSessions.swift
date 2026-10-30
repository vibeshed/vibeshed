import Darwin
import Foundation

/// Finds the Claude sessions running right now, and which of them are blocked on the
/// user, from the record each running Claude Code process keeps in
/// `~/.claude/sessions/<pid>.json`.
///
/// Terminal sessions and the ones Claude Desktop hosts both keep one. Its `status` is
/// "busy", "idle" or "waiting", and a waiting record names what it waits for in
/// `waitingFor`: "permission prompt", "input needed" (a question or an MCP prompt),
/// "dialog open" and so on. That is what Claude Desktop lists under "Needs Your Input".
/// The format is undocumented; this follows Claude Code 2.1.308.
enum AnthropicLiveSessions {
    /// One process's record.
    struct Record {
        let pid: pid_t
        /// The CLI session id.
        let sessionID: String
        /// The `local_…` id, for a session Claude Desktop hosts.
        let hostSessionID: String?
        /// When the record was first written, in milliseconds since 1970.
        let startedAt: Double
        /// When the process last rewrote the record, in milliseconds since 1970.
        let updatedAt: Double
        /// What the session waits for; nil unless its status is "waiting".
        let waitingFor: String?

        init?(_ json: [String: Any]) {
            guard let pid = (json["pid"] as? Int).flatMap(pid_t.init(exactly:)),
                  let sessionID = json["sessionId"] as? String,
                  let startedAt = json["startedAt"] as? Double,
                  // A pid from another domain (a VM, a remote host) means nothing here.
                  (json["pidDomain"] as? String ?? "darwin") == "darwin"
            else { return nil }
            self.pid = pid
            self.sessionID = sessionID
            self.startedAt = startedAt
            updatedAt = json["updatedAt"] as? Double ?? startedAt
            hostSessionID = json["hostSessionId"] as? String
            waitingFor = json["status"] as? String == "waiting"
                ? json["waitingFor"] as? String ?? "input"
                : nil
        }
    }

    /// `~/.claude/sessions`.
    static var standardDirectory: URL {
        AnthropicSessionReader.Locations.standard.claudeDirectory
            .appendingPathComponent("sessions")
    }

    /// What each waiting session waits for, keyed by its CLI session id and, for one
    /// Claude Desktop hosts, by its desktop id too.
    static func waiting(
        in directory: URL,
        isLive: (Record) -> Bool = isRunning
    ) -> [String: String] {
        var waiting: [String: String] = [:]
        for record in liveRecords(in: directory, isLive: isLive) {
            guard let waitingFor = record.waitingFor else { continue }
            waiting[record.sessionID] = waitingFor
            if let host = record.hostSessionID {
                waiting[host] = waitingFor
            }
        }
        return waiting
    }

    /// The process running the CLI session `sessionID`, whatever its status: where to
    /// go back to instead of resuming the session a second time. When two processes
    /// hold it, the one that wrote last.
    static func running(
        _ sessionID: String,
        in directory: URL = standardDirectory,
        isLive: (Record) -> Bool = isRunning
    ) -> Record? {
        liveRecords(in: directory, isLive: isLive)
            .filter { $0.sessionID == sessionID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func liveRecords(
        in directory: URL,
        isLive: (Record) -> Bool
    ) -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { AIJSONL.object(at: directory.appendingPathComponent($0)).flatMap(Record.init) }
            .filter(isLive)
    }

    /// A process that dies without cleaning up leaves its record behind, and its pid
    /// can go to a new process. So the record counts only while its pid runs a process
    /// that started before the record was written.
    static func isRunning(_ record: Record) -> Bool {
        guard let process = ProcessSnapshot(pid: record.pid) else { return false }
        // A second of slack for the two clocks' rounding.
        return process.startTime.timeIntervalSince1970 * 1000 <= record.startedAt + 1000
    }
}
