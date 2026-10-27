import Foundation
@testable import Vibeshed
import XCTest

final class ITermScriptTests: XCTestCase {
    private let palette = (try? ThemePalette.resolve(BuiltInThemes.dracula.colors, mode: .dark))
        ?? ThemePalette(mode: .dark, colors: [:])

    private static let propertyCount = 23
    private static let allSessions = "every session of every tab of every window"

    func testApplySetsEachPropertyOnEverySessionAtOnce() {
        let script = ITermTarget.applyScript(palette)
        let sets = script.components(separatedBy: "\n").filter { $0.hasPrefix("set ") }
        XCTAssertEqual(sets.count, Self.propertyCount)
        XCTAssertTrue(sets.allSatisfy { $0.contains(" of \(Self.allSessions) to {") })
        let background = "set background color of \(Self.allSessions) to \(palette.background.appleScriptList)"
        XCTAssertTrue(script.contains(background))
        XCTAssertFalse(script.contains("repeat"))
        XCTAssertTrue(script.contains("ignoring application responses"))
        XCTAssertTrue(script.contains("end ignoring\ncount windows\nend tell"), "waits for the sets to land")
    }

    func testSnapshotReadsEachPropertyOnce() {
        let script = ITermTarget.snapshotScript
        XCTAssertTrue(script.contains("set ids to id of \(Self.allSessions)"))
        XCTAssertEqual(script.components(separatedBy: " of \(Self.allSessions)").count - 1, Self.propertyCount + 1)
    }

    func testRestoreGroupsSessionsSharingAValue() throws {
        let shared = Array(repeating: "1, 2, 3", count: Self.propertyCount - 1)
        let output = [
            (["A"] + ["10, 20, 30"] + shared).joined(separator: "|"),
            (["B"] + ["40, 50, 60"] + shared).joined(separator: "|"),
            "garbage line",
        ].joined(separator: "\n")
        let script = try XCTUnwrap(ITermTarget.restoreScript(snapshot: output))
        let sets = script.components(separatedBy: "\n").filter { $0.hasPrefix("set ") }

        XCTAssertEqual(sets.count, Self.propertyCount + 1, "one per property, plus the background that differs")
        XCTAssertTrue(sets.contains("set background color of (\(Self.allSessions) whose id is \"A\") to {10, 20, 30}"))
        XCTAssertTrue(sets.contains("set background color of (\(Self.allSessions) whose id is \"B\") to {40, 50, 60}"))
        let both = "whose id is \"A\" or id is \"B\""
        XCTAssertTrue(sets.contains("set foreground color of (\(Self.allSessions) \(both)) to {1, 2, 3}"))
    }

    func testRestoreNeedsAtLeastOneSession() {
        XCTAssertNil(ITermTarget.restoreScript(snapshot: ""))
        XCTAssertNil(ITermTarget.restoreScript(snapshot: "A|1, 2, 3"))
    }
}

final class ProcessSignalTests: XCTestCase {
    func testFindsAndProbesProcessesByName() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        XCTAssertTrue(ProcessSignal.pids(named: "sleep").contains(child.processIdentifier))
        // Signal 0 only checks the process could be signalled; nothing is delivered.
        XCTAssertGreaterThanOrEqual(ProcessSignal.send(0, toProcessesNamed: "sleep"), 1)
        XCTAssertTrue(ProcessSignal.pids(named: "no-such-process-vibeshed").isEmpty)
    }

    func testNeverIncludesItself() throws {
        let ownName = try XCTUnwrap(ProcessInfo.processInfo.arguments.first.map { URL(fileURLWithPath: $0) })
            .lastPathComponent
        XCTAssertFalse(ProcessSignal.pids(named: ownName).contains(getpid()))
    }
}
