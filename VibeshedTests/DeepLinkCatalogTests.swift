@testable import Vibeshed
import XCTest

/// Web links rewritten to their apps' own links, and the ones left alone.
final class DeepLinkCatalogTests: XCTestCase {
    private func appLink(_ string: String, among apps: Set<String>? = nil) -> String? {
        DeepLinkCatalog.link(for: URL(string: string)!, among: apps)?.url.absoluteString
    }

    func testMeetings() {
        XCTAssertEqual(
            appLink("https://us06web.zoom.us/j/12345678901?pwd=abc"),
            "zoommtg://zoom.us/join?confno=12345678901&pwd=abc"
        )
        XCTAssertNil(appLink("https://zoom.us/pricing"), "only meeting links")
        XCTAssertEqual(
            appLink("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d"),
            "msteams:/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d",
            "keeps the encoded path and query as they are"
        )
        XCTAssertNil(appLink("https://teams.microsoft.com/v2/"))
    }

    func testSlack() {
        XCTAssertEqual(appLink("https://app.slack.com/client/T0123/C0456"), "slack://channel?team=T0123&id=C0456")
        XCTAssertEqual(appLink("https://app.slack.com/client/T0123/C0456/thread/C0456-1.2"),
                       "slack://channel?team=T0123&id=C0456")
        XCTAssertEqual(appLink("https://app.slack.com/client/T0123"), "slack://open?team=T0123")
        XCTAssertNil(appLink("https://acme.slack.com/archives/C0456/p123"), "no team ID to open it by")
    }

    func testWorkspaceApps() {
        XCTAssertEqual(
            appLink("https://linear.app/acme/issue/ENG-12/fix-it"), "linear://acme/issue/ENG-12/fix-it"
        )
        XCTAssertNil(appLink("https://linear.app/changelog/2026-10-01"), "the marketing site stays in the browser")
        XCTAssertEqual(
            appLink("https://www.notion.so/acme/Roadmap-1a2b3c?pvs=4"),
            "notion://www.notion.so/acme/Roadmap-1a2b3c?pvs=4"
        )
        XCTAssertEqual(appLink("https://notion.so/1a2b3c"), "notion://www.notion.so/1a2b3c")
        XCTAssertNil(appLink("https://www.notion.so/pricing"))
        XCTAssertEqual(
            appLink("https://discord.com/channels/@me/123/456"), "discord://discord.com/channels/@me/123/456"
        )
        XCTAssertNil(appLink("https://discord.com/download"))
    }

    func testMessengers() {
        XCTAssertEqual(appLink("https://t.me/durov"), "tg://resolve?domain=durov")
        XCTAssertEqual(appLink("https://t.me/durov/42"), "tg://resolve?domain=durov&post=42")
        XCTAssertEqual(appLink("https://t.me/s/durov"), "tg://resolve?domain=durov")
        XCTAssertEqual(appLink("https://t.me/c/1234/56"), "tg://privatepost?channel=1234&post=56")
        XCTAssertEqual(appLink("https://t.me/+AbCdEf"), "tg://join?invite=AbCdEf")
        XCTAssertEqual(appLink("https://t.me/joinchat/AbCdEf"), "tg://join?invite=AbCdEf")
        XCTAssertNil(appLink("https://t.me/"))
        XCTAssertEqual(appLink("https://wa.me/15551234567?text=hi%20there"),
                       "whatsapp://send?phone=15551234567&text=hi%20there")
        XCTAssertEqual(appLink("https://api.whatsapp.com/send?phone=15551234567"),
                       "whatsapp://send?phone=15551234567")
        XCTAssertNil(appLink("https://wa.me/message/ABC"))
    }

    func testMediaAndStores() {
        XCTAssertEqual(appLink("https://open.spotify.com/intl-de/album/4aawyAB9vmqN3uQ7FjRGTy?si=x"),
                       "spotify:album:4aawyAB9vmqN3uQ7FjRGTy")
        XCTAssertNil(appLink("https://open.spotify.com/genre/x"))
        XCTAssertEqual(
            appLink("https://music.apple.com/us/album/x/123?i=4"), "music://music.apple.com/us/album/x/123?i=4"
        )
        XCTAssertEqual(appLink("https://apps.apple.com/app/id123"), "macappstore://apps.apple.com/app/id123")
        XCTAssertEqual(appLink("https://maps.apple.com/?q=coffee&ll=1,2"), "maps://?q=coffee&ll=1,2")
        XCTAssertNil(appLink("https://maps.apple.com/place?auid=1"), "only the query form maps:// documents")
        XCTAssertEqual(appLink("https://store.steampowered.com/app/620/Portal_2/"), "steam://store/620")
        XCTAssertEqual(appLink("https://steamcommunity.com/id/x"), "steam://openurl/https://steamcommunity.com/id/x")
    }

    func testLeavesOtherLinksAlone() {
        XCTAssertNil(appLink("https://github.com/vibeshed/vibeshed"))
        XCTAssertNil(appLink("https://example.com/t.me"))
        XCTAssertNil(appLink("slack://channel?team=T&id=C"), "already an app link")
        XCTAssertNil(appLink("https://notzoom.us/j/123456789"), "not a subdomain of zoom.us")
        XCTAssertNotNil(appLink("https://zoom.us/j/123456789"), "zoom.us itself")
    }

    func testOnlyTheNamedApps() {
        XCTAssertNil(appLink("https://app.slack.com/client/T1/C1", among: ["zoom"]))
        XCTAssertNotNil(appLink("https://app.slack.com/client/T1/C1", among: ["zoom", "slack"]))
        XCTAssertEqual(DeepLinkCatalog.link(for: URL(string: "https://t.me/durov")!)?.appName, "Telegram")
    }

    func testInstalledOnlyWhenSomethingOpensTheAppLink() {
        let url = URL(string: "https://app.slack.com/client/T1/C1")!
        XCTAssertNil(DeepLinkCatalog.installedLink(for: url, canOpen: { _ in false }))
        XCTAssertEqual(
            DeepLinkCatalog.installedLink(for: url, canOpen: { $0.scheme == "slack" })?.url.absoluteString,
            "slack://channel?team=T1&id=C1"
        )
    }

    func testAppIDsAreUnique() {
        XCTAssertEqual(Set(DeepLinkCatalog.appIDs).count, DeepLinkCatalog.appIDs.count)
    }
}
