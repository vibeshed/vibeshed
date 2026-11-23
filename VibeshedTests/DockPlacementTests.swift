import CoreGraphics
@testable import Vibeshed
import XCTest

/// A hidden Dock gives its edge back to windows. On macOS 27.2 `visibleFrame` keeps
/// reserving a hidden Dock's strip, so Maximize stopped 95pt short of a right-hand Dock's
/// edge (the frames below are that display's, measured in an app process).
final class DockPlacementTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 2250, height: 1500)
    /// The display less its 30pt menu bar.
    private let filled = CGRect(x: 0, y: 0, width: 2250, height: 1470)

    func testHiddenDockOnTheRightGivesItsEdgeBack() {
        let visible = CGRect(x: 0, y: 0, width: 2155, height: 1470)
        let dock = DockPlacement(edge: .right, autohide: true)
        XCTAssertEqual(dock.usableFrame(frame: display, visible: visible), filled)
    }

    func testHiddenDockAtTheBottomGivesItsEdgeBack() {
        let visible = CGRect(x: 0, y: 95, width: 2250, height: 1375)
        let dock = DockPlacement(edge: .bottom, autohide: true)
        XCTAssertEqual(dock.usableFrame(frame: display, visible: visible), filled)
    }

    func testHiddenDockOnTheLeftGivesItsEdgeBack() {
        let visible = CGRect(x: 95, y: 0, width: 2155, height: 1470)
        let dock = DockPlacement(edge: .left, autohide: true)
        XCTAssertEqual(dock.usableFrame(frame: display, visible: visible), filled)
    }

    func testShownDockKeepsItsStrip() {
        let visible = CGRect(x: 0, y: 0, width: 2155, height: 1470)
        let dock = DockPlacement(edge: .right, autohide: false)
        XCTAssertEqual(dock.usableFrame(frame: display, visible: visible), visible)
    }

    /// A display without the Dock (here the portrait one left of the main display) has no
    /// strip on that edge; only its menu bar stays out.
    func testDisplayWithoutTheDockIsUnchanged() {
        let portrait = CGRect(x: -1500, y: -412, width: 1500, height: 2250)
        let visible = CGRect(x: -1500, y: -412, width: 1500, height: 2220)
        for edge in [DockPlacement.Edge.bottom, .left, .right] {
            let dock = DockPlacement(edge: edge, autohide: true)
            XCTAssertEqual(dock.usableFrame(frame: portrait, visible: visible), visible, "\(edge)")
        }
    }

    func testMaximizeFillsUpToThePaddingWhenTheDockHides() {
        let usable = DockPlacement(edge: .right, autohide: true)
            .usableFrame(frame: display, visible: CGRect(x: 0, y: 0, width: 2155, height: 1470))
        let padding = PaddingConfig(top: 4, bottom: 4, left: 5, right: 4, gap: 4)
        let frame = WindowSizing.maximize(screenFrame: usable, padding: padding)
        XCTAssertEqual(frame.maxX, 2250 - 4)
    }
}
