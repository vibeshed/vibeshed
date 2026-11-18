import Foundation

/// Launches apps through `/usr/bin/open` rather than `NSWorkspace`, so they don't become
/// Vibeshed's children in LaunchServices.
///
/// LaunchServices files an app that `NSWorkspace` launches under the launching app. If that
/// child has no Dock icon (System Events, a menu bar app, an app that hides its icon) and
/// outlives Vibeshed, LaunchServices keeps Vibeshed's entry after Vibeshed exits, marked
/// "exited-with-subordinates", and hands the child on to the next Vibeshed that starts. Until
/// the child quits, no termination is reported for any of them: whatever asked Vibeshed to
/// quit sees `NSRunningApplication.isTerminated` stay false and concludes the quit was
/// ignored, though Vibeshed exited at once. `open` has no LaunchServices entry of its own,
/// so the apps it starts have no parent.
enum AppLauncher {
    struct LaunchError: LocalizedError {
        /// The app's name, or its bundle identifier.
        let app: String

        var errorDescription: String? {
            "Couldn't open \(app)"
        }
    }

    /// Opens the app at `url`, bringing it to the front when `activates`.
    static func open(_ url: URL, activates: Bool = true) async throws {
        let name = url.deletingPathExtension().lastPathComponent
        try await run(arguments(appAt: url, activates: activates), app: name)
    }

    /// Opens the app with `bundleID`, bringing it to the front when `activates`.
    static func open(bundleID: String, activates: Bool = true) async throws {
        try await run(arguments(bundleID: bundleID, activates: activates), app: bundleID)
    }

    static func arguments(appAt url: URL, activates: Bool) -> [String] {
        (activates ? [] : ["-g"]) + ["-a", url.path]
    }

    static func arguments(bundleID: String, activates: Bool) -> [String] {
        (activates ? [] : ["-g"]) + ["-b", bundleID]
    }

    /// Returns once `open` has handed the launch to LaunchServices.
    private static func run(_ arguments: [String], app: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Off the cooperative pool: waitUntilExit() blocks its thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain before waiting, so a full pipe can't block `open`'s exit.
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let output = String(data: errorData, encoding: .utf8) ?? ""
                    let status = process.terminationStatus
                    Log.app.error(
                        """
                        open \(arguments, privacy: .public) exited \(status, privacy: .public): \
                        \(output, privacy: .public)
                        """
                    )
                    continuation.resume(throwing: LaunchError(app: app))
                    return
                }
                continuation.resume()
            }
        }
    }
}
