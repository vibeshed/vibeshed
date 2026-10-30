import AppKit
import Foundation
import OSLog

private let log = Log.module("ai")

/// Takes the user back to the terminal tab a running CLI agent lives in, so reopening a
/// live session doesn't start a second process on the same conversation.
enum AITerminalFocus {
    /// The app a process's terminal belongs to.
    enum Host: Equatable {
        case iTerm
        case terminal
        /// Any other app (Ghostty, an editor's terminal…). Its tabs can't be found by
        /// tty, so the whole app comes forward.
        case app(pid_t)
    }

    /// Where a process runs: the app hosting its terminal and the tab's tty.
    struct Location: Equatable {
        let host: Host
        let tty: String
    }

    /// Brings forward the tab `pid` runs in, off the calling thread. Runs `otherwise`
    /// instead when it can't: the process has no terminal, no app hosts it (tmux, ssh),
    /// or its tab is gone.
    static func focus(pid: pid_t, otherwise: @escaping @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            if let location = location(of: pid), await focus(location) { return }
            otherwise()
        }
    }

    /// Nil when `pid` has no tty or no terminal app above it.
    static func location(of pid: pid_t) -> Location? {
        guard let process = ProcessSnapshot(pid: pid), let tty = process.tty else { return nil }
        for ancestor in process.ancestors() {
            let app = NSRunningApplication(processIdentifier: ancestor.pid)
            if let host = host(
                name: ancestor.name,
                bundleID: app?.bundleIdentifier,
                isRegularApp: app?.activationPolicy == .regular,
                pid: ancestor.pid
            ) {
                return Location(host: host, tty: tty)
            }
        }
        return nil
    }

    /// Which terminal an ancestor process is, if it is one. iTerm runs shells under an
    /// `iTermServer-<version>` daemon, which is no app and can outlive iTerm itself.
    static func host(name: String, bundleID: String?, isRegularApp: Bool, pid: pid_t) -> Host? {
        if bundleID == ITermTarget.bundleID || name.hasPrefix("iTermServer") { return .iTerm }
        if bundleID == TerminalTarget.bundleID { return .terminal }
        return isRegularApp ? .app(pid) : nil
    }

    /// Whether the tab, or for `.app` the app, came forward.
    static func focus(_ location: Location) async -> Bool {
        guard let script = script(for: location) else {
            guard case let .app(pid) = location.host else { return false }
            return await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
            }
        }
        do {
            let output = try await AppleScriptRunner.run(script)
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "found"
        } catch {
            log.error(
                "Focusing \(location.tty, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Selects the tab whose tty is `location.tty` and prints "found", or prints
    /// "missing". Nil for a host that can't be scripted.
    static func script(for location: Location) -> String? {
        let tty = location.tty.escapedForAppleScript
        switch location.host {
        case .iTerm:
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                if miniaturized of w then set miniaturized of w to false
                                select w
                                select t
                                select s
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "missing"
            end tell
            """
        case .terminal:
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            if miniaturized of w then set miniaturized of w to false
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
                return "missing"
            end tell
            """
        case .app:
            return nil
        }
    }
}
