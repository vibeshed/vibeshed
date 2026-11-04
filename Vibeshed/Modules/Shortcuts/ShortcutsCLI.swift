import Foundation

struct ShortcutInfo: Sendable, Equatable {
    let name: String
    let id: String
    /// The folder it's filed in, nil for none.
    let folder: String?
}

/// Lists and runs the user's shortcuts: the Shortcuts app or a stand-in in tests.
protocol ShortcutsRunning: Sendable {
    func list() async throws -> [ShortcutInfo]
    /// Runs a shortcut by name or identifier with `input` as text, and returns what it
    /// output: one entry per item, as text (a dictionary as JSON), in order. A `timeout`
    /// stops one still running after that many seconds.
    func run(_ shortcut: String, input: String?, timeout: TimeInterval?) async throws -> [Data]
}

/// `/usr/bin/shortcuts`, the Shortcuts app's command-line tool. It's the one supported
/// way into other apps' App Intents: a shortcut can search Notes, Mail and the rest with
/// their own actions, and hand Vibeshed what it found.
struct ShortcutsCLI: ShortcutsRunning {
    var executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Every shortcut with its folder: `list` names none, so each folder is listed too.
    func list() async throws -> [ShortcutInfo] {
        let all = try await Self.entries(output(["list", "--show-identifiers"]))
        let folderNames = try await (String(bytes: output(["list", "--folders"]), encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        var folderByID: [String: String] = [:]
        for folder in folderNames {
            for entry in try await Self.entries(output(["list", "--folder-name", folder, "--show-identifiers"])) {
                folderByID[entry.id] = folder
            }
        }
        return all.map { ShortcutInfo(name: $0.name, id: $0.id, folder: folderByID[$0.id]) }
    }

    /// Text goes in on standard input (`--input-path -`). Output goes to a `.txt` path
    /// rather than standard output, which stays empty when the shortcut outputs a list: at
    /// the path the tool writes one item as a file, or a list as a folder of them.
    func run(_ shortcut: String, input: String?, timeout: TimeInterval?) async throws -> [Data] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeshed-shortcut-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        var arguments = ["run", shortcut, "--output-path", outputURL.path]
        if input != nil {
            arguments += ["--input-path", "-"]
        }
        _ = try await output(arguments, input: input.map { Data($0.utf8) }, timeout: timeout)
        return try Self.items(at: outputURL)
    }

    /// What a run wrote at `url`: nothing when the shortcut output nothing, a file for one
    /// item, or a folder with a file per item for a list. Those are named after their text,
    /// so they're put back in the order the tool wrote them.
    static func items(at url: URL) throws -> [Data] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        guard isFolder.boolValue else { return [try Data(contentsOf: url)] }
        let files = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        )
        let written = try files.map { file in
            (file, try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
        }
        return try written.sorted { $0.1 < $1.1 }.map { try Data(contentsOf: $0.0) }
    }

    private func output(_ arguments: [String], input: Data? = nil, timeout: TimeInterval? = 10) async throws -> Data {
        let result = try await ProcessRunner.run(executableURL, arguments: arguments, input: input, timeout: timeout)
        guard result.status == 0 else {
            throw ShortcutsError.failed(result.errorMessage)
        }
        return result.stdout
    }

    /// `list --show-identifiers` lines: `Name (UUID)`. A name may hold parentheses itself,
    /// so only a UUID in the last pair counts.
    static func entries(_ data: Data) -> [(name: String, id: String)] {
        (String(bytes: data, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let id = String(line[open.upperBound ..< line.index(before: line.endIndex)])
            guard UUID(uuidString: id) != nil else { return nil }
            return (String(line[..<open.lowerBound]), id)
        }
    }
}

enum ShortcutsError: LocalizedError, Equatable {
    case failed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message.isEmpty ? "The shortcut failed" : message
        case let .notFound(name): "There's no shortcut named \u{201C}\(name)\u{201D}"
        }
    }
}
