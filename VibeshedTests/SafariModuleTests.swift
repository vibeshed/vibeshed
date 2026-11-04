@testable import Vibeshed
import XCTest

/// History, Favorites and iCloud Tabs read from fixture files.
final class SafariReaderTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    func testHistoryReadsTheWriteAheadLogAndSkipsRedirectsAndFailures() throws {
        let fixture = try SafariFixture()
        try fixture.writeHistory([
            .init(url: "https://github.com/vibeshed/vibeshed/pull/99", visitCount: 2, visits: [
                .init(ago: hour, title: "Cut a release with one command"),
                .init(ago: 3 * day, title: "Older title"),
            ]),
            // http → https: only ever a redirect.
            .init(url: "http://github.com/", visits: [.init(ago: 2 * hour, title: nil, redirected: true)]),
            .init(url: "https://down.example/", visits: [.init(ago: 2 * hour, title: "Down", loaded: false)]),
            // The latest visit has no title; the one before does.
            .init(url: "https://news.ycombinator.com/", visitCount: 50, visits: [
                .init(ago: 2 * day, title: nil),
                .init(ago: 4 * day, title: "Hacker News"),
            ]),
            .init(url: "about:blank", visits: [.init(ago: hour, title: "Blank")]),
            .init(url: "https://developer.apple.com/documentation/swiftui/", visits: [.init(ago: 5 * day, title: nil)]),
            // The same page at an anchor: the earlier visit is folded into the later one.
            .init(url: "https://github.com/vibeshed/vibeshed/pull/99#discussion", visits: [
                .init(ago: 2 * day, title: "Cut a release with one command"),
            ]),
        ], now: now)

        let entries = try SafariHistoryReader.read(at: fixture.files.history)

        XCTAssertEqual(entries.map(\.url), [
            "https://github.com/vibeshed/vibeshed/pull/99",
            "https://news.ycombinator.com/",
            "https://developer.apple.com/documentation/swiftui/",
        ])
        XCTAssertEqual(entries[0].title, "Cut a release with one command")
        XCTAssertEqual(entries[0].lastVisited.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate - hour,
                       accuracy: 0.001)
        XCTAssertEqual(entries[0].visitCount, 2)
        XCTAssertEqual(entries[1].title, "Hacker News")
        XCTAssertEqual(entries[2].displayTitle, "developer.apple.com/documentation/swiftui")
    }

    func testNoHistoryFileIsNoHistory() throws {
        let fixture = try SafariFixture()
        XCTAssertEqual(try SafariHistoryReader.read(at: fixture.files.history), [])
    }

    func testUnreadableHistoryIsAnError() throws {
        let fixture = try SafariFixture()
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: fixture.files.history))
        XCTAssertThrowsError(try SafariHistoryReader.read(at: fixture.files.history))
    }

    func testFavoritesAreTheBookmarksBarInOrderWithFolders() throws {
        let favorites = SafariFavoritesReader.favorites(in: SafariFixture.bookmarks)
        XCTAssertEqual(favorites, [
            SafariFavorite(title: "Vibeshed", url: "https://vibeshed.dev/", folders: []),
            SafariFavorite(title: "Swift Forums", url: "https://forums.swift.org/", folders: ["Dev"]),
        ])
    }

    func testFavoritesReadFromBookmarksPlist() throws {
        let fixture = try SafariFixture()
        XCTAssertEqual(try SafariFavoritesReader.read(at: fixture.files.bookmarks), [])
        try fixture.writeBookmarks()
        XCTAssertEqual(try SafariFavoritesReader.read(at: fixture.files.bookmarks).map(\.title), [
            "Vibeshed", "Swift Forums",
        ])
    }

    func testCloudTabsLeaveOutThisMacAndRepeatsMostRecentlyViewedFirst() throws {
        let fixture = try SafariFixture()
        try fixture.writeCloudTabs(
            devices: [
                ("MAC", "Studio Mac", "com.apple.macbookpro-14-2021-silver"),
                ("PHONE", "Pocket", "com.apple.iphone-13-mini-2"),
                ("PAD", "Slate", "com.apple.ipad13-4"),
            ],
            tabs: [
                .init(device: "MAC", url: "https://local.example/", title: "Open here", viewedAgo: 60),
                .init(device: "PHONE", url: "https://a.example/", title: "A", viewedAgo: 600),
                .init(device: "PHONE", url: "https://shared.example/", title: "Shared", viewedAgo: hour, pinned: true),
                .init(device: "PAD", url: "https://shared.example/", title: "Shared", viewedAgo: 2 * hour),
                .init(device: "PAD", url: "https://b.example/", title: nil, viewedAgo: 300),
                .init(device: "PAD", url: "javascript:void(0)", title: "Script", viewedAgo: 10),
            ],
            now: now
        )

        let tabs = try SafariCloudTabsReader.read(at: fixture.files.cloudTabs, thisMac: "Studio Mac")

        XCTAssertEqual(tabs.map(\.url), ["https://b.example/", "https://a.example/", "https://shared.example/"])
        XCTAssertEqual(tabs.map(\.device.name), ["Slate", "Pocket", "Pocket"])
        XCTAssertEqual(tabs[0].displayTitle, "b.example")
        XCTAssertTrue(tabs[2].isPinned)
        XCTAssertEqual(tabs.map(\.device.kind), [.pad, .phone, .phone])
    }

    func testCloudTabsWithoutViewTimesStillRead() throws {
        let fixture = try SafariFixture()
        try fixture.writeCloudTabs(
            devices: [("PHONE", "Pocket", "com.apple.iphone-13-mini-2")],
            tabs: [.init(device: "PHONE", url: "https://a.example/", title: "A", viewedAgo: 0)],
            now: now,
            withViewTimes: false
        )
        let tabs = try SafariCloudTabsReader.read(at: fixture.files.cloudTabs, thisMac: nil)
        XCTAssertEqual(tabs.map(\.url), ["https://a.example/"])
        XCTAssertNil(tabs[0].lastViewed)
    }

    func testDeviceKinds() {
        func kind(_ type: String?) -> SafariDevice.Kind {
            SafariDevice(id: "", name: "", typeIdentifier: type).kind
        }
        XCTAssertEqual(kind("com.apple.iphone-13-mini-2"), .phone)
        XCTAssertEqual(kind("com.apple.ipad13-4"), .pad)
        XCTAssertEqual(kind("com.apple.macbookpro-14-2021-silver"), .laptop)
        XCTAssertEqual(kind("com.apple.imac-2021-blue"), .desktop)
        XCTAssertEqual(kind("com.apple.macmini-2023"), .desktop)
        XCTAssertEqual(kind(nil), .other)
    }

    func testURLPieces() {
        XCTAssertEqual(SafariURL.split("https://www.github.com/a/b?c=1").host, "www.github.com")
        XCTAssertEqual(SafariURL.split("https://www.github.com/a/b?c=1#d").path, "/a/b")
        XCTAssertEqual(SafariURL.split("file:///Users/me/a.html").path, "/Users/me/a.html")
        XCTAssertEqual(SafariURL.split("file:///Users/me/a.html").host, "")
        XCTAssertEqual(SafariURL.address("https://www.icloud.com/mail/?x=1"), "icloud.com/mail")
        XCTAssertEqual(SafariURL.address("https://news.ycombinator.com/"), "news.ycombinator.com")
        XCTAssertEqual(SafariURL.split("https://example.com?q").host, "example.com")
        XCTAssertEqual(SafariURL.display("https://www.example.com/docs/"), "example.com/docs")
        XCTAssertTrue(SafariURL.isListable("HTTPS://example.com"))
        XCTAssertFalse(SafariURL.isListable("javascript:void(0)"))
        XCTAssertFalse(SafariURL.isListable("about:blank"))
    }
}

/// Matching and ranking history pages.
final class SafariHistoryIndexTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func entry(_ url: String, _ title: String, daysAgo: Double = 1, score: Int = 100) -> SafariHistoryEntry {
        SafariHistoryEntry(
            url: url, title: title, lastVisited: now.addingTimeInterval(-daysAgo * 86400), visitCount: 1, score: score
        )
    }

    func testFoldsToLowercaseWords() {
        XCTAssertEqual(
            String(bytes: SearchWords.fold("Make the Website—Satisfying! #66"), encoding: .utf8),
            " make the website satisfying 66"
        )
        XCTAssertEqual(String(bytes: SearchWords.fold("Привет, Мир"), encoding: .utf8), " привет мир")
        XCTAssertEqual(SearchWords.queryWords("  Swift  UI ").count, 2)
    }

    func testWordPrefixNeedsEveryWordToStartAWord() {
        let index = SafariHistoryIndex(entries: [
            entry("https://github.com/vibeshed/vibeshed/pull/99", "Cut a release with one command"),
            entry("https://example.com/", "Release notes"),
        ])
        XCTAssertEqual(index.search("rel vibe", mode: .wordPrefix, limit: 10, now: now).map(\.entry.title), [
            "Cut a release with one command",
        ])
        XCTAssertEqual(index.search("hub", mode: .wordPrefix, limit: 10, now: now).count, 0)
        XCTAssertEqual(index.search("hub", mode: .anywhere, limit: 10, now: now).map(\.entry.title), [
            "Cut a release with one command",
        ])
    }

    func testTitleMatchesRankAboveAddressMatches() {
        let index = SafariHistoryIndex(entries: [
            entry("https://example.com/swift-guide", "A guide"),
            entry("https://swift.example/", "Home"),
            entry("https://example.com/a", "Swift Concurrency"),
        ])
        XCTAssertEqual(index.search("swift", mode: .wordPrefix, limit: 10, now: now).map(\.entry.title), [
            "Swift Concurrency", "Home", "A guide",
        ])
    }

    func testFrequentRecentPagesBreakTies() {
        let index = SafariHistoryIndex(entries: [
            entry("https://a.example/", "Swift old", daysAgo: 60, score: 20),
            entry("https://b.example/", "Swift popular", daysAgo: 1, score: 5000),
            entry("https://c.example/", "Swift recent", daysAgo: 0, score: 100),
        ])
        let ranked = index.search("swift", mode: .wordPrefix, limit: 10, now: now).map(\.entry.title)
        XCTAssertEqual(ranked.last, "Swift old")
        XCTAssertEqual(ranked.first, "Swift popular")
    }

    func testEmptyQueryIsMostRecentFirst() {
        let index = SafariHistoryIndex(entries: [
            entry("https://a.example/", "Newest", daysAgo: 0),
            entry("https://b.example/", "Older", daysAgo: 2),
        ])
        XCTAssertEqual(index.search("", mode: .anywhere, limit: 1, now: now).map(\.entry.title), ["Newest"])
    }

    func testFindsEntriesByHashOfTheirAddress() {
        let index = SafariHistoryIndex(entries: [entry("https://a.example/", "A")])
        XCTAssertEqual(index.entry(hash: StableID.hash("https://a.example/"))?.title, "A")
        XCTAssertNil(index.entry(hash: "nope"))
    }
}

/// The module over fixture files.
final class SafariModuleTests: XCTestCase {
    private let now = Date()
    private var fixture: SafariFixture!
    private let opened = OpenedURLs()

    override func setUpWithError() throws {
        fixture = try SafariFixture()
        try fixture.writeHistory([
            .init(url: "https://github.com/vibeshed/vibeshed/pull/99", visits: [
                .init(ago: 3600, title: "Cut a release with one command"),
            ]),
            .init(url: "https://news.ycombinator.com/", visitCount: 50, score: 5000, visits: [
                .init(ago: 7200, title: "Hacker News"),
            ]),
        ], now: now)
        try fixture.writeBookmarks()
        try fixture.writeCloudTabs(
            devices: [("MAC", "Studio Mac", "com.apple.macbookpro"), ("PHONE", "Pocket", "com.apple.iphone-15")],
            tabs: [
                .init(device: "MAC", url: "https://local.example/", title: "Here", viewedAgo: 1),
                .init(device: "PHONE", url: "https://recipes.example/", title: "Recipes", viewedAgo: 60),
            ],
            now: now
        )
    }

    private func makeModule(_ config: SafariConfig = SafariConfig()) async -> SafariModule {
        let opened = opened
        let module = SafariModule(files: fixture.files, thisMac: "Studio Mac", safariPath: nil) { url in
            opened.append(url)
        }
        await module.configDidUpdate(config)
        await module.loadHistoryIfNeeded()
        return module
    }

    private func ids(_ actions: [any Action]) -> [String] {
        actions.map(\.id.actionName)
    }

    private let empty = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: "", systemContext: nil)

    func testMainSearchHasFavoritesTabsAndHistoryForThreeLetters() async {
        let module = await makeModule()
        let listed = await module.provideActions(query: "", scoring: empty)
        XCTAssertEqual(ids(listed).filter { !$0.hasPrefix("search") }, [
            "favorite." + StableID.hash("https://vibeshed.dev/"),
            "favorite." + StableID.hash("https://forums.swift.org/"),
            "cloudTab." + StableID.hash("PHONE" + "https://recipes.example/"),
        ])
        XCTAssertEqual(ids(listed).filter { $0.hasPrefix("search") }, [
            "searchHistory", "searchFavorites", "searchCloudTabs",
        ])

        let short = await module.provideActions(query: "ha", scoring: empty)
        XCTAssertFalse(ids(short).contains { $0.hasPrefix("history.") })

        let typed = await module.provideActions(query: "hack", scoring: empty)
        let history = typed.compactMap { $0 as? SafariAction }.filter { $0.id.actionName.hasPrefix("history.") }
        XCTAssertEqual(history.map(\.title), ["Hacker News"])
        XCTAssertEqual(history.first?.subtitle, "news.ycombinator.com")
        XCTAssertTrue(history.first?.requiresWordPrefixMatch == true)
        XCTAssertEqual(history.first?.deduplicationKey, "https://news.ycombinator.com")
    }

    func testRowsFollowTheConfig() async {
        var config = SafariConfig()
        config.showFavorites = false
        config.showCloudTabs = false
        config.historyResults = 0
        let module = await makeModule(config)
        let listed = await module.provideActions(query: "hacker", scoring: empty)
        XCTAssertEqual(ids(listed), ["searchHistory", "searchFavorites", "searchCloudTabs"])

        config = SafariConfig()
        config.enabledActions = ["searchHistory", "history"]
        await module.configDidUpdate(config)
        let enabled = await module.provideActions(query: "hacker", scoring: empty)
        XCTAssertEqual(ids(enabled), ["searchHistory", "history." + StableID.hash("https://news.ycombinator.com/")])
    }

    func testRowsResolveByIDAndOpenInSafari() async throws {
        let module = await makeModule()
        let historyID = SafariModule.actionID(prefix: SafariModule.historyPrefix, "https://news.ycombinator.com/")
        let action = await module.action(id: historyID)
        XCTAssertEqual(action?.title, "Hacker News")
        _ = try await action?.run(with: ParameterValues())

        let favoriteID = SafariModule.actionID(prefix: SafariModule.favoritePrefix, "https://forums.swift.org/")
        _ = try await module.action(id: favoriteID)?.run(with: ParameterValues())

        XCTAssertEqual(opened.urls, ["https://news.ycombinator.com/", "https://forums.swift.org/"])
        let missing = await module.action(id: ActionID("safari/history.nope"))
        XCTAssertNil(missing)
    }

    func testSearchOptions() async throws {
        let module = await makeModule()
        let history = ActionID("safari/searchHistory")
        let recent = await module.provideParameterOptions(for: "page", in: history, query: "")
        XCTAssertEqual(recent.map(\.label), ["Cut a release with one command", "Hacker News"])

        let found = await module.provideParameterOptions(for: "page", in: history, query: "ycomb")
        XCTAssertEqual(found.map(\.id), ["https://news.ycombinator.com/"])

        let hit = await module.provideParameterOptions(for: "page", in: history, query: "news")
        XCTAssertEqual(hit.first?.labelHighlightRanges?.count, 1)

        let favorites = await module.provideParameterOptions(
            for: "page", in: ActionID("safari/searchFavorites"), query: ""
        )
        XCTAssertEqual(favorites.map(\.subtitle), ["vibeshed.dev", "Dev · forums.swift.org"])

        let tabs = await module.provideParameterOptions(for: "page", in: ActionID("safari/searchCloudTabs"), query: "")
        XCTAssertEqual(tabs.map(\.label), ["Recipes"])
        XCTAssertEqual(tabs.first?.iconName, "iphone")

        let search = await module.action(id: history)
        _ = try await search?.run(with: ParameterValues(["page": "https://news.ycombinator.com/"]))
        XCTAssertEqual(opened.urls, ["https://news.ycombinator.com/"])
    }

    func testUnreadableHistoryShowsWhy() async throws {
        let broken = try SafariFixture()
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: broken.files.history))
        let module = SafariModule(files: broken.files, thisMac: nil, safariPath: nil) { _ in }
        let options = await module.provideParameterOptions(
            for: "page", in: ActionID("safari/searchHistory"), query: ""
        )
        XCTAssertEqual(options.map(\.id), [""])
        XCTAssertEqual(options.first?.label, "Couldn't read Safari's history")
    }

    func testHistoryIsReadAgainOnceSafariWrites() async throws {
        let module = await makeModule()
        let before = await module.history.count
        try fixture.writeHistoryVisit(url: "https://new.example/", title: "Brand New", now: now)
        await module.loadHistoryIfNeeded()
        let after = await module.history.entries.map(\.title)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.first, "Brand New")
    }

    /// A search results page names the query in its title and address. Its address words
    /// aren't keywords, so it can't match as strongly as an action named for the query.
    func testHistoryRowsDontOutrankActionsNamedForTheQuery() async {
        let module = await makeModule()
        let page = SafariHistoryEntry(
            url: "https://www.google.com/search?client=safari&q=icloud", title: "icloud - Google Search",
            lastVisited: Date(), visitCount: 3, score: 100
        )
        let row = await module.historyAction(SafariHistoryIndex.Match(entry: page, rank: 0, frecency: 1))
        XCTAssertEqual(row.subtitle, "google.com/search")
        let corpus = await (module.fixedActions() + [row]).map { ScorableAction(action: $0) }
        let scoring = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: "icloud", systemContext: nil)
        let ranked = ActionScorer.scoreAndRank(corpus: corpus, query: "icloud", scoring: scoring).0.map(\.id.actionName)
        XCTAssertEqual(ranked.first, "searchCloudTabs")
    }

    func testValidation() {
        XCTAssertTrue(SafariModule.validate(SafariConfig()).isValid)
        var config = SafariConfig()
        config.historyResults = -1
        XCTAssertFalse(SafariModule.validate(config).isValid)
    }
}
