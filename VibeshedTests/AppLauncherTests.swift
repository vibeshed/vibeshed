import Foundation
@testable import Vibeshed
import XCTest

final class AppLauncherTests: XCTestCase {
    func testOpensAppByPathInTheForeground() {
        let url = URL(fileURLWithPath: "/Applications/Some App.app")
        XCTAssertEqual(AppLauncher.arguments(appAt: url, activates: true), ["-a", "/Applications/Some App.app"])
    }

    func testBackgroundLaunchByBundleIDDoesNotActivate() {
        XCTAssertEqual(
            AppLauncher.arguments(bundleID: "com.apple.systemevents", activates: false),
            ["-g", "-b", "com.apple.systemevents"]
        )
    }

    func testMissingAppThrowsWithItsName() async {
        do {
            try await AppLauncher.open(URL(fileURLWithPath: "/nonexistent/Vibeshed Test Missing.app"))
            XCTFail("expected a LaunchError")
        } catch let error as AppLauncher.LaunchError {
            XCTAssertEqual(error.localizedDescription, "Couldn't open Vibeshed Test Missing")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
