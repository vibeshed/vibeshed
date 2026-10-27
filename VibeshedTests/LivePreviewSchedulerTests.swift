@testable import Vibeshed
import XCTest

/// When the picker sends a highlighted option's live preview: once the highlight rests,
/// after the typing pauses, and only the latest option.
@MainActor
final class LivePreviewSchedulerTests: XCTestCase {
    /// Short enough to keep the suite fast; the gaps between them leave room for a slow runner.
    private let timing = LivePreviewScheduler.Timing(selectionDelay: .milliseconds(40), typingPause: .milliseconds(250))

    private actor Deliveries {
        var ids: [String] = []

        func append(_ id: String) {
            ids.append(id)
        }
    }

    private func schedule(_ id: String, on scheduler: LivePreviewScheduler, into deliveries: Deliveries) {
        scheduler.schedule(id) { await deliveries.append(id) }
    }

    /// Waits up to two seconds for `expected`, then checks it.
    private func waitFor(
        _ expected: [String],
        in deliveries: Deliveries,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 200 where await deliveries.ids != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ids = await deliveries.ids
        XCTAssertEqual(ids, expected, file: file, line: line)
    }

    func testDelayIsTheSelectionDelayOrTheRestOfTheTypingPause() {
        let delay = { LivePreviewScheduler.delay(self.timing, sinceFilterEdit: $0) }
        XCTAssertEqual(delay(nil), .milliseconds(40))
        XCTAssertEqual(delay(.milliseconds(50)), .milliseconds(200))
        XCTAssertEqual(delay(.milliseconds(230)), .milliseconds(40))
        XCTAssertEqual(delay(.seconds(5)), .milliseconds(40))
    }

    /// Arrowing through several options delivers only the one the highlight rests on.
    func testRapidHighlightsDeliverOnlyTheLast() async throws {
        let scheduler = LivePreviewScheduler(timing: timing)
        let deliveries = Deliveries()
        for id in ["a", "b", "c"] {
            schedule(id, on: scheduler, into: deliveries)
        }
        try await waitFor(["c"], in: deliveries)
        try await Task.sleep(for: .milliseconds(100))
        let ids = await deliveries.ids
        XCTAssertEqual(ids, ["c"], "nothing else arrives later")
    }

    /// The 2026-10-27 recording: typing "latte" previewed Lupine, the top match for "l".
    /// A highlight that follows the filter waits for the typing to pause.
    func testHighlightsWhileTypingWaitForTheTypingToPause() async throws {
        let scheduler = LivePreviewScheduler(timing: timing)
        let deliveries = Deliveries()
        let start = ContinuousClock.now
        // The top match after "l", "la" and "lat".
        for top in ["lupine", "latte", "latte"] {
            scheduler.filterEdited()
            schedule(top, on: scheduler, into: deliveries)
            try await Task.sleep(for: .milliseconds(60)) // past the selection delay, inside the pause
        }
        let early = await deliveries.ids
        XCTAssertEqual(early, [], "no intermediate match was previewed")
        try await waitFor(["latte"], in: deliveries)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(120 + 250))
    }

    /// A keystroke after the highlight landed pushes the pending preview back.
    func testFilterEditDefersThePendingPreview() async throws {
        let scheduler = LivePreviewScheduler(timing: timing)
        let deliveries = Deliveries()
        schedule("a", on: scheduler, into: deliveries)
        scheduler.filterEdited()
        try await Task.sleep(for: .milliseconds(120)) // the selection delay alone would have fired
        let early = await deliveries.ids
        XCTAssertEqual(early, [])
        try await waitFor(["a"], in: deliveries)
    }

    /// Coming back to what's already previewed drops the pending one: nothing to apply.
    func testReturningToTheDeliveredOptionCancelsThePendingOne() async throws {
        let scheduler = LivePreviewScheduler(timing: timing)
        let deliveries = Deliveries()
        schedule("a", on: scheduler, into: deliveries)
        try await waitFor(["a"], in: deliveries)

        schedule("b", on: scheduler, into: deliveries)
        schedule("a", on: scheduler, into: deliveries)
        XCTAssertNil(scheduler.pendingOptionID)
        try await Task.sleep(for: .milliseconds(150))
        let ids = await deliveries.ids
        XCTAssertEqual(ids, ["a"])
    }

    /// The same highlight reported again (another context change) doesn't restart the wait.
    func testRepeatedScheduleKeepsTheTimer() async throws {
        let scheduler = LivePreviewScheduler(timing: timing)
        let deliveries = Deliveries()
        let start = ContinuousClock.now
        schedule("a", on: scheduler, into: deliveries)
        try await Task.sleep(for: .milliseconds(25))
        schedule("a", on: scheduler, into: deliveries)
        try await waitFor(["a"], in: deliveries)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(25 + 40 + 400))
    }

    /// Escape or a commit before the highlight settles sends nothing, and the next
    /// session starts from scratch.
    func testResetDropsThePendingPreview() async throws {
        let scheduler = LivePreviewScheduler(timing: timing)
        let deliveries = Deliveries()
        schedule("a", on: scheduler, into: deliveries)
        try await waitFor(["a"], in: deliveries)
        schedule("b", on: scheduler, into: deliveries)
        scheduler.reset()
        try await Task.sleep(for: .milliseconds(150))
        var ids = await deliveries.ids
        XCTAssertEqual(ids, ["a"])

        schedule("a", on: scheduler, into: deliveries)
        try await waitFor(["a", "a"], in: deliveries)
        ids = await deliveries.ids
        XCTAssertEqual(ids, ["a", "a"], "a new session previews its first option again")
    }
}
