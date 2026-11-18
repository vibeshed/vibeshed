import Foundation
import OSLog

private let log = Log.module("openai")

/// Reads Codex thread history from `~/.codex`.
///
/// Codex Desktop's thread catalog (`CodexThreadCatalog`) decides which threads are
/// listed, with their titles, times and hosts, whenever the app has written one: it
/// covers threads on SSH hosts and leaves out the helper threads the app hides. Without
/// it (the CLI alone), the session files below decide. Either way the transcripts give
/// the model and fill in a missing directory or branch.
///
/// Two files describe a Codex session. `session_index.jsonl` is a flat, current index
/// of thread ids to human titles, and each thread's `sessions/<y>/<m>/<d>/rollout-*.jsonl`
/// transcript opens with a `session_meta` record carrying the working directory and git
/// branch, then records a `turn_context` with the model on every turn. The index is
/// read in full because it is small; transcripts are only opened, at the head and the
/// tail, for the handful of threads actually being shown.
enum OpenAISessionReader {
    static var codexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    static func readSessions(
        limit: Int,
        root: URL = codexDirectory
    ) -> [AISession] {
        let transcripts = transcriptIndex(root: root)
        let cataloged = CodexThreadCatalog.threads(
            databasePath: CodexThreadCatalog.databasePath(root: root), limit: limit
        )
        let newest = cataloged.flatMap { $0.isEmpty ? nil : $0.map(Candidate.init) }
            ?? fileCandidates(transcripts: transcripts, root: root, limit: limit)

        let metas = transcriptMetas(
            paths: newest.map { transcripts[$0.id]?.path }
        )
        let sessions = zip(newest, metas).map { candidate, meta in
            AISession(
                sessionID: candidate.id,
                source: OpenAIProvider.codex,
                title: candidate.title ?? "Session \(candidate.id.prefix(8))",
                project: candidate.cwd ?? meta.cwd,
                model: meta.model,
                branch: candidate.branch ?? meta.branch,
                timestamp: candidate.timestamp,
                host: candidate.host
            )
        }
        log.debug("Codex sessions found: \(sessions.count, privacy: .public)")
        return sessions
    }

    // MARK: - Index

    private struct Candidate {
        let id: String
        let title: String?
        let timestamp: Date
        var cwd: String?
        var branch: String?
        var host: AISessionHost?

        init(id: String, title: String?, timestamp: Date) {
            self.id = id
            self.title = title
            self.timestamp = timestamp
        }

        init(_ thread: CodexThreadCatalog.Thread) {
            self.init(id: thread.id, title: thread.title, timestamp: thread.updatedAt)
            cwd = thread.cwd
            branch = thread.branch
            host = thread.host
        }
    }

    /// The `limit` newest threads by the session files alone. A thread can appear in
    /// either file: the index lags for brand-new threads, and old transcripts outlive
    /// their index entries. Union both, preferring the index's title and timestamp.
    private static func fileCandidates(
        transcripts: [String: Transcript],
        root: URL,
        limit: Int
    ) -> [Candidate] {
        var candidates: [String: Candidate] = [:]
        for (id, transcript) in transcripts {
            candidates[id] = Candidate(
                id: id, title: nil, timestamp: transcript.modified
            )
        }
        for thread in indexedThreads(root: root) {
            candidates[thread.id] = Candidate(
                id: thread.id,
                title: thread.title,
                timestamp: thread.updatedAt
            )
        }
        return Array(
            candidates.values
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(limit)
        )
    }

    private struct IndexedThread {
        let id: String
        let title: String?
        let updatedAt: Date
    }

    private static func indexedThreads(root: URL) -> [IndexedThread] {
        let path = root.appendingPathComponent("session_index.jsonl").path
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return AIJSONL.objects(atPath: path).compactMap { json in
            guard let id = json["id"] as? String else { return nil }
            let updated = (json["updated_at"] as? String)
                .flatMap { formatter.date(from: $0) }
            return IndexedThread(
                id: id,
                title: (json["thread_name"] as? String)?.asSessionTitle(),
                updatedAt: updated ?? .distantPast
            )
        }
    }

    // MARK: - Transcripts

    private struct Transcript {
        let path: String
        let modified: Date
    }

    /// Maps thread id to its transcript, from `rollout-<timestamp>-<id>.jsonl` names.
    /// Only directory metadata is read here; file contents stay untouched.
    private static func transcriptIndex(root: URL) -> [String: Transcript] {
        let sessions = root.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            log.debug("Codex sessions directory not found")
            return [:]
        }

        var index: [String: Transcript] = [:]
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let id = threadID(fromTranscriptName: name)
            else { continue }
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            index[id] = Transcript(path: url.path, modified: modified)
        }
        return index
    }

    /// Extracts the trailing UUID from `rollout-2026-08-24T14-16-28-<uuid>.jsonl`.
    private static func threadID(fromTranscriptName name: String) -> String? {
        let stem = name
            .dropFirst("rollout-".count)
            .dropLast(".jsonl".count)
        // The timestamp prefix also uses `-`, so take the last five
        // hyphen-separated groups, which is exactly one UUID.
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    /// Reads transcript headers in parallel. Each is an independent file read plus a
    /// JSON parse of a large system-prompt record, so doing them serially dominated
    /// the panel-open path.
    private static func transcriptMetas(
        paths: [String?]
    ) -> [TranscriptMeta] {
        guard !paths.isEmpty else { return [] }
        // Safe: concurrentPerform writes one distinct index per iteration and
        // returns only after every iteration has completed.
        nonisolated(unsafe) var results = [TranscriptMeta](
            repeating: .empty, count: paths.count
        )
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let path = paths[index] else { return }
            results[index] = TranscriptMeta(path: path)
        }
        return results
    }

    /// The working directory and branch from the `session_meta` record at the head of
    /// a transcript, and the model from its newest `turn_context`, so a thread that
    /// switched models mid-way shows the one it last ran on.
    private struct TranscriptMeta {
        let cwd: String?
        let model: String?
        let branch: String?

        static let empty = TranscriptMeta(cwd: nil, model: nil, branch: nil)

        init(cwd: String?, model: String?, branch: String?) {
            self.cwd = cwd
            self.model = model
            self.branch = branch
        }

        init(path: String) {
            var cwd: String?
            var branch: String?
            var firstModel: String?
            // The header sits at the very top of the transcript, ahead of the
            // conversation itself.
            for record in AIJSONL.headObjects(atPath: path, limit: 8) {
                let payload = record["payload"] as? [String: Any] ?? [:]
                switch record["type"] as? String {
                case "session_meta":
                    cwd = payload["cwd"] as? String
                    branch = Self.branch(in: payload)
                case "turn_context":
                    firstModel = firstModel ?? payload["model"] as? String
                case nil:
                    // Older Codex builds open with an untyped header that
                    // carries `git` at the top level and no model.
                    branch = branch ?? Self.branch(in: record)
                default:
                    continue
                }
            }
            var latestModel: String?
            AIJSONL.scanTail(
                atPath: path, containing: [#""turn_context""#]
            ) { record in
                guard record["type"] as? String == "turn_context",
                      let payload = record["payload"] as? [String: Any],
                      let model = payload["model"] as? String
                else { return false }
                latestModel = model
                return true
            }
            self.init(
                cwd: cwd,
                model: (latestModel ?? firstModel)
                    .map(OpenAIModelName.displayName(for:)),
                branch: branch
            )
        }

        private static func branch(in record: [String: Any]) -> String? {
            (record["git"] as? [String: Any])?["branch"] as? String
        }
    }
}
