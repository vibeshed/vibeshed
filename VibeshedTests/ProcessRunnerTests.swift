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
}
