import Foundation

/// Reads the model and git branch a Claude Code session last ran with, and when it was
/// last active, from its transcript, `~/.claude/projects/<project-slug>/<session-id>.jsonl`.
///
/// Transcripts reach hundreds of megabytes, so only their tails are read, and only for
/// the sessions actually being listed.
enum AnthropicTranscripts {
    struct Context: Equatable {
        let model: String?
        let branch: String?
        /// When the session last did something (see `lastActivity(atPath:)`), which can
        /// be well after its last prompt while Claude works on.
        var lastActivity: Date?

        static let empty = Context(model: nil, branch: nil)
    }

    /// Fills in each session's model and branch from its transcript, preferring the
    /// transcript's values: they are the newest the session recorded. Activity the
    /// transcript records after the session's timestamp moves the timestamp up to it.
    static func enrich(
        _ sessions: [AISession],
        projectsDirectory: URL
    ) -> [AISession] {
        guard sessions.contains(where: { $0.cliSessionID != nil }) else {
            return sessions
        }
        let index = transcriptPaths(in: projectsDirectory)
        let paths = sessions.map { $0.cliSessionID.flatMap { index[$0] } }
        // Safe: concurrentPerform writes one distinct index per iteration and
        // returns only after every iteration has completed.
        nonisolated(unsafe) var contexts = [Context](
            repeating: .empty, count: paths.count
        )
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let path = paths[index] else { return }
            contexts[index] = context(atPath: path)
        }
        return zip(sessions, contexts).map { session, context in
            session.updating(
                model: context.model, branch: context.branch, lastActivity: context.lastActivity
            )
        }
    }

    /// Maps session id to transcript path across all project directories. Listing the
    /// directories avoids re-deriving Claude Code's project slug, which hashes long
    /// paths; subagent transcripts live one level deeper and are skipped.
    static func transcriptPaths(in projects: URL) -> [String: String] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: projects.path) else {
            return [:]
        }
        var paths: [String: String] = [:]
        for slug in slugs {
            let directory = projects.appendingPathComponent(slug)
            // Plain files in `projects/` fail to list and are skipped.
            let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(".jsonl".count))
                paths[id] = directory.appendingPathComponent(name).path
            }
        }
        return paths
    }

    /// Scans back from the end of the transcript to the newest assistant turn of the
    /// main conversation. Its `message.model` is the model, and the newest
    /// `gitBranch` stamped on any entry up to it is the branch. Transcripts written
    /// before Claude Code recorded branches simply yield no branch.
    static func context(atPath path: String) -> Context {
        var model: String?
        var branch: String?
        var sawBranch = false
        // Only entries naming a branch or an assistant turn can change the answer.
        let needles = [#""gitBranch""#, #""assistant""#]
        AIJSONL.scanTail(atPath: path, containing: needles) { record in
            // Subagent turns can run on a different model than the session.
            guard record["isSidechain"] as? Bool != true else { return false }
            if !sawBranch, let value = record["gitBranch"] as? String {
                sawBranch = true
                branch = value
            }
            guard record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let id = message["model"] as? String,
                  // Locally generated messages (errors, interrupts) are
                  // stamped `<synthetic>` rather than with a real model.
                  !id.hasPrefix("<")
            else { return false }
            model = AnthropicModelName.displayName(for: id)
            return true
        }
        return Context(
            model: model,
            branch: branch.flatMap(branchName),
            lastActivity: lastActivity(atPath: path)
        )
    }

    /// When the session last did something: the newest entry stamped with a time (a
    /// prompt, a turn, a tool result, a queued message). Not the file's modification
    /// date: Claude Desktop appends unstamped bookkeeping (`bridge-session`,
    /// `last-prompt`, `cost-state`) whenever it reattaches a session, even one that was
    /// only opened, which would float long-idle sessions to the top.
    static func lastActivity(atPath path: String) -> Date? {
        var activity: Date?
        AIJSONL.scanTail(atPath: path, containing: [#""timestamp""#]) { record in
            guard let stamp = record["timestamp"] as? String, let date = parseTimestamp(stamp) else {
                return false
            }
            activity = date
            return true
        }
        return activity
    }

    /// Transcript times are ISO 8601 in UTC, with milliseconds.
    private static func parseTimestamp(_ stamp: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
            ?? (try? Date.ISO8601FormatStyle().parse(stamp))
    }

    /// `HEAD` is what git reports on a detached checkout, which is no branch at all.
    private static func branchName(_ value: String) -> String? {
        value.isEmpty || value == "HEAD" ? nil : value
    }
}
