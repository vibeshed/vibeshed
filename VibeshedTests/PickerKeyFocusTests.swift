@testable import Vibeshed
import XCTest

/// Paste-on-select's ⌘V must wait until the picker panel resigns key, or it pastes
/// into the picker's search field instead of the app the user was in.
@MainActor
final class PickerKeyFocusTests: XCTestCase {
    func testReturnsAtOnceWhenPickerIsNotKey() async {
        let focus = PickerKeyFocus()
        let start = ContinuousClock.now
        let released = await focus.waitUntilReleased(timeout: .seconds(5))
        XCTAssertTrue(released)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testWaitsUntilPickerResignsKey() async {
        let focus = PickerKeyFocus()
        focus.setHeld(true)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            focus.setHeld(false)
        }

        let start = ContinuousClock.now
        let released = await focus.waitUntilReleased(timeout: .seconds(5))
        let waited = start.duration(to: .now)

        XCTAssertTrue(released)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(150), "returned before the picker let go")
        XCTAssertLessThan(waited, .seconds(5), "waited for the timeout instead of the release")
    }

    func testReleasesEveryWaiter() async {
        let focus = PickerKeyFocus()
        focus.setHeld(true)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            focus.setHeld(false)
        }

        async let first = focus.waitUntilReleased(timeout: .seconds(5))
        async let second = focus.waitUntilReleased(timeout: .seconds(5))
        let results = await [first, second]

        XCTAssertEqual(results, [true, true])
    }

    /// The picker reopened before its hide finished: it becomes key again and never
    /// lets go, so the wait gives up rather than pasting into it.
    func testGivesUpWhilePickerStaysKey() async {
        let focus = PickerKeyFocus()
        focus.setHeld(true)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            focus.setHeld(true)
        }

        let released = await focus.waitUntilReleased(timeout: .milliseconds(200))
        XCTAssertFalse(released)

        // A later release must not resume the timed-out wait a second time.
        focus.setHeld(false)
        let next = await focus.waitUntilReleased(timeout: .seconds(5))
        XCTAssertTrue(next)
    }
}
