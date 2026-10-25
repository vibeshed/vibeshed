import CoreText
@testable import Vibeshed
import XCTest

/// Registrations here use `.process` scope, so they end with the test run and never
/// reach the login session.
final class FontActivationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FontActivationTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyFilesOnDiskThatCoreTextDoesntListNeedRegistering() {
        let paths = ["/Fonts/Listed.ttf", "/Fonts/New.ttf", "/Fonts/Gone.ttf"]
        let unlisted = FontActivation.unlisted(paths, available: ["/Fonts/Listed.ttf"]) { $0 != "/Fonts/Gone.ttf" }
        XCTAssertEqual(unlisted, ["/Fonts/New.ttf"])
    }

    func testAvailableFontsAreListedByFile() {
        let available = FontActivation.availableFontPaths()
        XCTAssertTrue(available.contains("/System/Library/Fonts/Menlo.ttc"))
        XCTAssertFalse(available.contains { $0.contains("#") })
    }

    func testRegistersAFontFileCoreTextDoesntList() async throws {
        let copy = directory.appendingPathComponent("Menlo.ttc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc"), to: copy)

        let outcome = await FontActivation.activate([copy.path], scope: .process)
        XCTAssertEqual(outcome, FontActivation.Outcome(registered: [copy.path]))
        XCTAssertEqual(CTFontManagerGetScopeForURL(copy as CFURL), .process)
        // Registering it again isn't a failure.
        let again = await FontActivation.activate([copy.path], scope: .process)
        XCTAssertEqual(again.failed, [:])
        CTFontManagerUnregisterFontURLs([copy] as CFArray, .process, nil)
    }

    func testSkipsListedAndMissingFilesAndReportsOnesThatArentFonts() async throws {
        let notAFont = directory.appendingPathComponent("README.ttf")
        try Data("Not a font".utf8).write(to: notAFont)
        let gone = directory.appendingPathComponent("Gone.ttf")
        let paths = ["/System/Library/Fonts/Menlo.ttc", gone.path, notAFont.path]

        let outcome = await FontActivation.activate(paths, scope: .process)
        XCTAssertEqual(outcome.registered, [])
        XCTAssertEqual(outcome.failed, [notAFont.path: CTFontManagerError.unrecognizedFormat.rawValue])
        let nothing = await FontActivation.activate([], scope: .process)
        XCTAssertEqual(nothing, FontActivation.Outcome())
    }
}
