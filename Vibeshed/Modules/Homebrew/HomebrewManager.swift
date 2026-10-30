import AppKit
import OSLog

private let log = Log.module("homebrew")

enum HomebrewManager {
    struct PackageInfo: Sendable {
        let name: String
        let version: String?
        let description: String?
        let isCask: Bool
    }

    // MARK: - Search

    /// Names of the formulae or casks matching `query`, best matches first.
    static func search(_ query: String, isCask: Bool, brewPath: String) async throws -> [String] {
        let output = try await runBrew(brewPath, "search", isCask ? "--cask" : "--formula", query)
        return rankSearchResults(parseSearchResults(output), query: query)
    }

    /// Orders `brew search` hits, which come alphabetically, so the likeliest survive
    /// truncation: exact name, then prefix, then word-start, then other matches,
    /// shorter names first within each group. Tap prefixes (`user/tap/`) are ignored.
    static func rankSearchResults(_ names: [String], query: String) -> [String] {
        let query = query.lowercased()
        func group(_ base: String) -> Int {
            if base == query { return 0 }
            if base.hasPrefix(query) { return 1 }
            let words = base.split { "-@._".contains($0) }
            return words.contains { $0.hasPrefix(query) } ? 2 : 3
        }
        return names.enumerated()
            .map { index, name in
                let base = name.lowercased().split(separator: "/").last.map(String.init) ?? ""
                return (name: name, key: (group(base), base.count, index))
            }
            .sorted { $0.key < $1.key }
            .map(\.name)
    }

    // MARK: - Install / Uninstall

    static func installFormula(_ name: String, brewPath: String) async throws -> String {
        try await runBrew(brewPath, "install", "--formula", name)
    }

    static func installCask(_ name: String, brewPath: String) async throws -> String {
        try await runBrew(brewPath, "install", "--cask", name)
    }

    /// Brew's one-line install summary (the `🍺` line, e.g. `/opt/homebrew/Cellar/jq/1.7.1: 19 files, 1.3MB`),
    /// falling back to the last output line. Full install output is too noisy for a notification.
    static func installSummary(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let summary = lines.last { $0.hasPrefix("🍺") } ?? lines.last { !$0.isEmpty } ?? ""
        return summary.drop { $0 == "🍺" || $0.isWhitespace }.description
    }

    static func uninstallFormula(_ name: String, brewPath: String) async throws -> String {
        try await runBrew(brewPath, "uninstall", "--formula", name)
    }

    static func uninstallCask(_ name: String, brewPath: String) async throws -> String {
        try await runBrew(brewPath, "uninstall", "--cask", name)
    }

    // MARK: - Info

    /// Details for the named formulae or casks, looked up in one `brew info` run.
    /// Throws if any name is unknown: brew then prints nothing for the rest either.
    static func packages(_ names: [String], isCask: Bool, brewPath: String) async throws -> [HomebrewPackage] {
        guard !names.isEmpty else { return [] }
        let output = try await runBrew(brewPath, ["info", "--json=v2", isCask ? "--cask" : "--formula"] + names)
        return HomebrewPackage.parse(Data(output.utf8))
    }

    /// Details for every installed formula or cask, with `requiredBy` filled in.
    static func installedPackages(isCask: Bool, brewPath: String) async throws -> [HomebrewPackage] {
        let output = try await runBrew(brewPath, "info", "--json=v2", "--installed", isCask ? "--cask" : "--formula")
        return HomebrewPackage.linkingDependents(HomebrewPackage.parse(Data(output.utf8)))
            .sorted { $0.token.localizedStandardCompare($1.token) == .orderedAscending }
    }

    /// Installed locations of a cask's `app` artifacts (e.g. `/Applications/Foo.app`).
    /// Empty for casks that ship no app bundle (fonts, pkg installers, CLI tools).
    static func caskAppPaths(_ name: String, brewPath: String) async throws -> [String] {
        try await packages([name], isCask: true, brewPath: brewPath).flatMap(\.appPaths)
    }

    // MARK: - Launch

    /// Opens the first of `paths` that exists on disk. Returns the launched app's path.
    /// Through `AppLauncher`, since many casks are menu bar apps.
    static func launchFirstApp(at paths: [String]) async -> String? {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        do {
            try await AppLauncher.open(URL(fileURLWithPath: path))
            return path
        } catch {
            log.warning("Failed to launch \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Update / Upgrade

    static func update(brewPath: String) async throws -> String {
        try await runBrew(brewPath, "update")
    }

    static func upgrade(brewPath: String) async throws -> String {
        try await runBrew(brewPath, "upgrade")
    }

    static func outdated(brewPath: String) async throws -> [PackageInfo] {
        let output = try await runBrew(brewPath, "outdated", "--verbose")
        return output
            .split(separator: "\n")
            .compactMap { line -> PackageInfo? in
                let name = String(line.split(separator: " ").first ?? "")
                guard !name.isEmpty else { return nil }
                return PackageInfo(name: name, version: nil, description: String(line), isCask: false)
            }
    }

    // MARK: - Cleanup

    static func cleanup(brewPath: String) async throws -> String {
        try await runBrew(brewPath, "cleanup")
    }

    // MARK: - Private

    private static func parseSearchResults(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
    }

    @discardableResult
    private static func runBrew(_ brewPath: String, _ args: String...) async throws -> String {
        try await runBrew(brewPath, args)
    }

    private static func runBrew(_ brewPath: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: brewPath)
            task.arguments = args
            task.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
            ]

            let pipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errPipe

            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Drain both pipes concurrently before waiting on exit: brew output (e.g. `search`,
            // `list --versions`) regularly exceeds the 64KB pipe buffer, and waitUntilExit()
            // before reading deadlocks — the child blocks on a full-buffer write() while we
            // block waiting for it to exit. Draining stdout/stderr sequentially isn't enough
            // either, since the other pipe can fill up while we wait on the first.
            let readGroup = DispatchGroup()
            // Safe: readGroup.wait() below is a happens-before barrier against both writes.
            nonisolated(unsafe) var data = Data()
            nonisolated(unsafe) var errData = Data()
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.wait()
            task.waitUntilExit()

            let output = String(data: data, encoding: .utf8) ?? ""

            if task.terminationStatus != 0 {
                let errOutput = String(data: errData, encoding: .utf8) ?? ""
                let message = errOutput.isEmpty ? output : errOutput
                log.warning("brew \(args.joined(separator: " ")) failed: \(message, privacy: .public)")
                continuation
                    .resume(throwing: HomebrewError
                        .commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }

            continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum HomebrewError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message): message
        }
    }
}
