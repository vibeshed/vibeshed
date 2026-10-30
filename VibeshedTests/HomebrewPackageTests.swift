import Foundation
@testable import Vibeshed
import XCTest

final class HomebrewPackageTests: XCTestCase {
    // MARK: - Casks

    func testParsesCask() throws {
        let json = """
        {"formulae": [], "casks": [{
          "token": "firefox", "full_token": "firefox", "tap": "homebrew/cask",
          "name": ["Mozilla Firefox"], "desc": "Web browser", "homepage": "https://www.mozilla.org/firefox/",
          "version": "156.0.1", "installed": "155.0.1", "outdated": true, "pinned": false, "auto_updates": true,
          "conflicts_with": {"cask": ["firefox@beta", "firefox@esr"]}, "caveats": null,
          "artifacts": [
            {"uninstall": [{"quit": "org.mozilla.firefox"}]},
            {"app": ["Firefox.app"], "target": "/Applications/Firefox.app"},
            {"binary": ["/Applications/Firefox.app/Contents/MacOS/firefox"], "target": "/opt/homebrew/bin/firefox"}
          ],
          "deprecated": false, "deprecation_reason": null, "disabled": false, "disable_reason": null
        }]}
        """
        let package = try XCTUnwrap(HomebrewPackage.parse(Data(json.utf8)).first)

        XCTAssertEqual(package.token, "firefox")
        XCTAssertTrue(package.isCask)
        XCTAssertEqual(package.displayName, "Mozilla Firefox")
        XCTAssertEqual(package.description, "Web browser")
        XCTAssertEqual(package.homepage, "https://www.mozilla.org/firefox/")
        XCTAssertEqual(package.version, "156.0.1")
        XCTAssertEqual(package.installedVersion, "155.0.1")
        XCTAssertTrue(package.isOutdated)
        XCTAssertTrue(package.autoUpdates)
        XCTAssertEqual(package.conflicts, ["firefox@beta", "firefox@esr"])
        XCTAssertEqual(package.appPaths, ["/Applications/Firefox.app"])
        XCTAssertEqual(package.fontPaths, [])
        XCTAssertNil(package.caveats)
        XCTAssertNil(package.deprecation)
        XCTAssertNil(package.disabling)
    }

    func testFontCaskHasFontPathsAndNoAppPaths() {
        let json = """
        {"casks": [{"token": "font-fira-code", "artifacts": [
          {"font": ["ttf/FiraCode-Bold.ttf"], "target": "/Users/me/Library/Fonts/FiraCode-Bold.ttf"},
          {"font": ["ttf/FiraCode-Light.ttf"], "target": "/Users/me/Library/Fonts/FiraCode-Light.ttf"}
        ]}]}
        """
        let packages = HomebrewPackage.parse(Data(json.utf8))
        XCTAssertEqual(packages.map(\.appPaths), [[]])
        XCTAssertEqual(packages.first?.fontPaths, [
            "/Users/me/Library/Fonts/FiraCode-Bold.ttf", "/Users/me/Library/Fonts/FiraCode-Light.ttf",
        ])
        XCTAssertEqual(packages.first?.displayName, "font-fira-code")
        XCTAssertEqual(packages.first?.isInstalled, false)
    }

    func testParseReturnsNothingForMalformedJSON() {
        XCTAssertEqual(HomebrewPackage.parse(Data("Error: no such cask".utf8)), [])
    }

    // MARK: - Formulae

    func testParsesFormula() throws {
        let package = try formula("""
        {"name": "jq", "full_name": "jq", "tap": "homebrew/core",
         "desc": "Lightweight and flexible command-line JSON processor", "license": "MIT",
         "homepage": "https://jqlang.github.io/jq/", "versions": {"stable": "1.8.2", "head": "HEAD", "bottle": true},
         "dependencies": ["oniguruma"], "conflicts_with": [], "keg_only": false, "pinned": true, "outdated": true,
         "caveats": "  To use jq, run it.\\n",
         "installed": [{"version": "1.8.1", "installed_on_request": true, "runtime_dependencies": []}]}
        """)

        XCTAssertFalse(package.isCask)
        XCTAssertEqual(package.displayName, "jq")
        XCTAssertEqual(package.license, "MIT")
        XCTAssertEqual(package.version, "1.8.2")
        XCTAssertEqual(package.installedVersion, "1.8.1")
        XCTAssertFalse(package.isInstalledAsDependency)
        XCTAssertTrue(package.isPinned)
        XCTAssertEqual(package.dependencies, ["oniguruma"])
        XCTAssertEqual(package.caveats, "To use jq, run it.")
        XCTAssertEqual(package.tap, "homebrew/core")
    }

    func testFormulaInstalledForAnotherIsADependency() throws {
        let package = try formula("""
        {"name": "fmt", "installed": [{"version": "12.2.0", "installed_on_request": false}]}
        """)
        XCTAssertTrue(package.isInstalled)
        XCTAssertTrue(package.isInstalledAsDependency)
    }

    func testFormulaWithNoKegsIsNotInstalled() throws {
        let package = try formula(#"{"name": "jq", "installed": [], "desc": ""}"#)
        XCTAssertFalse(package.isInstalled)
        XCTAssertFalse(package.isInstalledAsDependency)
        XCTAssertNil(package.description)
    }

    func testParsesDeprecationAndDisabling() throws {
        let deprecated = try formula("""
        {"name": "tldr", "deprecated": true, "deprecation_reason": "unmaintained",
         "deprecation_replacement_formula": "tlrc", "deprecation_replacement_cask": null, "disabled": false}
        """)
        XCTAssertEqual(deprecated.deprecation, HomebrewPackage.Notice(reason: "unmaintained", replacement: "tlrc"))
        XCTAssertNil(deprecated.disabling)

        let disabled = try formula("""
        {"name": "old", "disabled": true, "disable_reason": "does_not_build", "disable_replacement_cask": "new"}
        """)
        XCTAssertEqual(disabled.disabling, HomebrewPackage.Notice(reason: "does_not_build", replacement: "new"))
    }

    func testLinkingDependentsListsWhatRequiresEachFormula() {
        let json = """
        {"formulae": [
          {"name": "ada-url", "dependencies": ["fmt"]},
          {"name": "fmt", "dependencies": []},
          {"name": "folly", "dependencies": ["fmt", "gflags"]}
        ]}
        """
        let packages = HomebrewPackage.linkingDependents(HomebrewPackage.parse(Data(json.utf8)))
        XCTAssertEqual(packages.map(\.requiredBy), [[], ["ada-url", "folly"], []])
    }

    // MARK: - Preview formatting

    func testVersionTextShowsUpgradeOnlyWhenOutdated() throws {
        let notInstalled = try formula(#"{"name": "jq", "versions": {"stable": "1.8.2"}}"#)
        XCTAssertEqual(HomebrewPackagePreview.versionText(notInstalled), "1.8.2")

        let outdated = try formula("""
        {"name": "jq", "versions": {"stable": "1.8.2"}, "outdated": true, "installed": [{"version": "1.8.1"}]}
        """)
        XCTAssertEqual(HomebrewPackagePreview.versionText(outdated), "1.8.1 → 1.8.2")

        let headOnly = try formula(#"{"name": "tip", "versions": {}, "installed": [{"version": "HEAD-1a2b3c"}]}"#)
        XCTAssertEqual(HomebrewPackagePreview.versionText(headOnly), "HEAD-1a2b3c")
    }

    func testVersionTextDropsCaskBuildUnlessOnlyTheBuildChanged() throws {
        let current = try cask(#"{"token": "claude", "version": "2.110.0,dfb2ba67", "installed": "2.110.0,dfb2ba67"}"#)
        XCTAssertEqual(HomebrewPackagePreview.versionText(current), "2.110.0")

        let rebuilt = try cask(#"{"token": "app", "version": "1.0,101", "installed": "1.0,100", "outdated": true}"#)
        XCTAssertEqual(HomebrewPackagePreview.versionText(rebuilt), "1.0,100 → 1.0,101")
    }

    func testDisplayURLDropsSchemeWWWAndTrailingSlash() {
        XCTAssertEqual(HomebrewPackagePreview.displayURL("https://www.mozilla.org/firefox/"), "mozilla.org/firefox")
        XCTAssertEqual(HomebrewPackagePreview.displayURL("http://example.com"), "example.com")
        XCTAssertEqual(HomebrewPackagePreview.displayURL("https://jqlang.github.io/jq/"), "jqlang.github.io/jq")
    }

    func testDescribeNotice() {
        XCTAssertEqual(
            HomebrewPackagePreview.describe("Deprecated", .init(reason: "unmaintained", replacement: "tlrc")),
            "Deprecated: unmaintained, replaced by tlrc"
        )
        XCTAssertEqual(
            HomebrewPackagePreview.describe("Disabled", .init(reason: "does_not_build", replacement: nil)),
            "Disabled: does not build"
        )
        XCTAssertEqual(HomebrewPackagePreview.describe("Disabled", .init(reason: nil, replacement: nil)), "Disabled")
    }

    // MARK: - Helpers

    private func formula(_ json: String) throws -> HomebrewPackage {
        try XCTUnwrap(HomebrewPackage.parse(Data(#"{"formulae": [\#(json)]}"#.utf8)).first)
    }

    private func cask(_ json: String) throws -> HomebrewPackage {
        try XCTUnwrap(HomebrewPackage.parse(Data(#"{"casks": [\#(json)]}"#.utf8)).first)
    }
}
