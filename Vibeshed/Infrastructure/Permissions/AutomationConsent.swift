import AppKit

/// macOS's per-app consent to send Apple events: "Vibeshed wants access to control …".
enum AutomationConsent {
    static let systemEvents = "com.apple.systemevents"
    static let finder = "com.apple.finder"

    enum Status: Sendable, Equatable {
        case allowed
        case denied
        /// The user hasn't been asked yet.
        case notAsked
        /// macOS only answers for, and asks about, apps that are running.
        case notRunning
    }

    /// Where consent stands for `bundleID`. With `ask`, shows macOS's dialog if the
    /// user hasn't answered yet and blocks until they do, so call it off the main thread.
    static func status(for bundleID: String, ask: Bool = false) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .denied }
        switch AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .notRunning
        default: return .denied
        }
    }

    /// Asks about each app in turn, one dialog at a time, and returns the answers.
    /// System Events only runs on demand, so it's started first. Other apps are asked
    /// only while they're open, since starting them just to ask would be intrusive;
    /// the rest ask the first time a module scripts them.
    static func ask(for bundleIDs: [String]) async -> [String: Status] {
        if bundleIDs.contains(systemEvents) {
            await launchInBackground(systemEvents)
        }
        var answers: [String: Status] = [:]
        for bundleID in bundleIDs {
            guard let answer = await answer(from: bundleID) else {
                // One stuck question could hold up the next as well: leave the rest
                // to ask when they're first scripted.
                break
            }
            answers[bundleID] = answer
        }
        return answers
    }

    /// Asking can hang for good when the app is running with no windows open (Apple
    /// Developer Forums thread 666528), so each answer gets this long.
    private static let answerTimeout: TimeInterval = 60

    /// Asks about one app on a background thread, since the call blocks until the user
    /// answers; nil when no answer came within `answerTimeout`.
    private static func answer(from bundleID: String) async -> Status? {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate(continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.resume(with: .success(status(for: bundleID, ask: true)))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + answerTimeout) {
                gate.resume(with: .success(nil))
            }
        }
    }

    /// Starts a faceless helper app and waits until it can receive Apple events.
    /// Started through `AppLauncher`: a System Events that NSWorkspace started would keep
    /// macOS from reporting Vibeshed as quit for as long as System Events runs.
    private static func launchInBackground(_ bundleID: String) async {
        guard status(for: bundleID) == .notRunning,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        else { return }
        do {
            try await AppLauncher.open(bundleID: bundleID, activates: false)
        } catch {
            Log.permissions.error(
                "Couldn't start \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        var attempts = 0
        while status(for: bundleID) == .notRunning, attempts < 20 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
