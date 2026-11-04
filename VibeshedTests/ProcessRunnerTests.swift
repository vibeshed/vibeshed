@testable import Vibeshed
import XCTest

/// Standard input in, both outputs back, and stopping a tool that runs too long.
final class ProcessRunnerTests: XCTestCase {
    func testPassesInputAndCollectsBothOutputs() async throws {
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat; echo oops >&2; exit 3"], input: Data("hello".utf8)
        )
        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(String(bytes: output.stdout, encoding: .utf8), "hello")
        XCTAssertEqual(output.errorMessage, "oops")
    }

    /// More than the pipe's 64 KB buffer: draining before waiting keeps it from blocking.
    func testLargeOutput() async throws {
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 300000 /dev/zero"]
        )
        XCTAssertEqual(output.stdout.count, 300_000)
    }

    func testWithoutInputStandardInputIsEmpty() async throws {
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 5)
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.isEmpty)
    }

    func testTimesOut() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunner.RunError, .timedOut(0.3))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testCancellingStopsTheTool() async throws {
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    /// A tool that ignores SIGTERM: the caller hears back at once, and the tool is killed
    /// once its grace period is up.
    func testCancellingAnswersAtOnceAndKillsAToolThatIgnoresStop() async throws {
        let (arguments, pidFile) = try stubbornTool()
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: arguments) }
        let pid = try await waitForPID(in: pidFile)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500), "doesn't wait for the tool")
        try await assertExits(pid)
    }

    func testTimeoutKillsAToolThatIgnoresStop() async throws {
        let (arguments, pidFile) = try stubbornTool()
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: arguments, timeout: 0.5)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunner.RunError, .timedOut(0.5))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        try await assertExits(try waitForPID(in: pidFile))
    }

    func testInputTooLarge() async {
        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data(count: ProcessRunner.maxInputSize)
            )
            XCTFail("expected inputTooLarge")
        } catch {
            XCTAssertEqual(error as? ProcessRunner.RunError, .inputTooLarge)
        }
    }

    // MARK: Helpers

    /// `sh` arguments for a tool that ignores SIGTERM (an ignored signal stays ignored across
    /// `exec`) and writes its PID to the returned file first.
    private func stubbornTool() throws -> (arguments: [String], pidFile: URL) {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("vibeshed-pid-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        return (["-c", "trap '' TERM; echo $$ > '\(pidFile.path)'; exec sleep 20"], pidFile)
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        for _ in 0 ..< 50 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file.path])
    }

    /// Gone, and reaped, within the kill grace period and a margin.
    private func assertExits(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 40 {
            if kill(pid, 0) != 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        kill(pid, SIGKILL)
        XCTFail("process \(pid) still running", file: file, line: line)
    }
}
