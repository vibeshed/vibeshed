import Foundation
@testable import Vibeshed
import XCTest

/// Going back to the terminal tab a running CLI agent lives in: reading a process's
/// tty and parents, telling which terminal app hosts it, and the scripts that select
/// its tab.
final class AITerminalFocusTests: XCTestCase {
    // MARK: - Process snapshot

    func testSnapshotOfThisProcess() throws {
        let snapshot = try XCTUnwrap(ProcessSnapshot(pid: getpid()))
        XCTAssertEqual(snapshot.parentPID, getppid())
        XCTAssertLessThan(snapshot.startTime, Date())
        XCTAssertEqual(snapshot.ancestors().first?.pid, getppid())
    }

    /// `script` runs its command under a new pseudo-terminal, like a terminal tab does.
    func testSnapshotReadsTheTTYAProcessRunsIn() throws {
        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        host.arguments = ["-q", "/dev/null", "/bin/sh", "-c", "echo $$; exec sleep 30"]
        let input = Pipe()
        let output = Pipe()
        host.standardInput = input
        host.standardOutput = output
        try host.run()
        defer {
            host.terminate()
            host.waitUntilExit()
        }
        let printed = String(bytes: output.fileHandleForReading.availableData, encoding: .utf8)
        let pid = try XCTUnwrap(printed.flatMap { pid_t($0.filter(\.isNumber)) })

        let snapshot = try XCTUnwrap(ProcessSnapshot(pid: pid))
        let tty = try XCTUnwrap(snapshot.tty)
        XCTAssertTrue(tty.hasPrefix("/dev/ttys"), tty)
        XCTAssertEqual(snapshot.ancestors().first?.pid, host.processIdentifier)
        XCTAssertNil(ProcessSnapshot(pid: host.processIdentifier)?.tty, "script itself runs without one")
    }

    func testNoSnapshotForAnExitedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertNil(ProcessSnapshot(pid: process.processIdentifier))
    }

    /// Nothing to go back to, so the caller's own way of reopening runs.
    func testFocusFallsBackWhenTheProcessIsGone() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let fellBack = expectation(description: "fallback runs")
        AITerminalFocus.focus(pid: process.processIdentifier) { fellBack.fulfill() }
        await fulfillment(of: [fellBack], timeout: 5)
    }

    // MARK: - Hosts

    func testRecognizesTerminalHosts() {
        XCTAssertEqual(host("iTerm2", ITermTarget.bundleID), .iTerm)
        // iTerm's shells hang off this daemon, which isn't an app.
        XCTAssertEqual(host("iTermServer-3.7.", nil, isRegularApp: false), .iTerm)
        XCTAssertEqual(host("Terminal", TerminalTarget.bundleID), .terminal)
        XCTAssertEqual(host("ghostty", "com.mitchellh.ghostty", pid: 42), .app(42))
    }

    /// A shell, `login` or an app's helper sits between the agent and its app.
    func testSkipsProcessesThatAreNoApp() {
        XCTAssertNil(host("login", nil, isRegularApp: false))
        XCTAssertNil(host("tmux", nil, isRegularApp: false))
        XCTAssertNil(host("Code Helper", "com.microsoft.VSCode.helper", isRegularApp: false))
    }

    // MARK: - Scripts

    func testITermScriptSelectsTheSessionWithTheTTY() throws {
        let script = try XCTUnwrap(AITerminalFocus.script(for: .init(host: .iTerm, tty: "/dev/ttys003")))
        XCTAssertTrue(script.contains(#"tell application "iTerm2""#))
        XCTAssertTrue(script.contains(#"if tty of s is "/dev/ttys003" then"#))
        XCTAssertTrue(script.contains(#"return "missing""#))
    }

    func testTerminalScriptSelectsTheTabWithTheTTY() throws {
        let script = try XCTUnwrap(AITerminalFocus.script(for: .init(host: .terminal, tty: "/dev/ttys004")))
        XCTAssertTrue(script.contains(#"tell application "Terminal""#))
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys004" then"#))
    }

    func testOtherAppsHaveNoScript() {
        XCTAssertNil(AITerminalFocus.script(for: .init(host: .app(42), tty: "/dev/ttys005")))
    }

    // MARK: - Helpers

    private func host(
        _ name: String, _ bundleID: String?, isRegularApp: Bool = true, pid: pid_t = 1
    ) -> AITerminalFocus.Host? {
        AITerminalFocus.host(name: name, bundleID: bundleID, isRegularApp: isRegularApp, pid: pid)
    }
}
