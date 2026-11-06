import UniformTypeIdentifiers
@testable import Vibeshed
import XCTest

private let home = "/Users/me"
private let day: TimeInterval = 86400

private func recent(_ path: String, daysAgo: Double = 1, type: String? = nil, now: Date = Date()) -> RecentFile {
    RecentFile(path: path, contentType: type, lastUsed: now.addingTimeInterval(-daysAgo * day), size: 2048, home: home)
}

/// Which files Finder's Recents lists, and how their folders read.
final class RecentFilePathsTests: XCTestCase {
    func testListsUserFilesIncludingCloudFolders() {
        let listed = [
            "/Users/me/Downloads/invoice.pdf",
            "/Users/me/notes.txt",
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2025.pdf",
            "/Users/me/Library/CloudStorage/Dropbox/Photos/id.jpg",
            // A package is a file of its own; only what's inside one is left out.
            "/Users/me/Documents/Deck.key",
            "/Users/me/Projects/App/App.xcodeproj",
            "/Users/me/Projects/v1.2/notes.txt",
            "/Volumes/Backup/scan.pdf",
        ]
        for path in listed {
            XCTAssertTrue(RecentFilePaths.isListable(path, home: home), path)
        }
        let hidden = [
            "/Users/me/Library/Containers/com.example/Data/Documents/a.pdf",
            "/Users/me/Library/Application Support/Example/state.json",
            "/Users/me/.config/vibeshed/config.yaml",
            "/Users/me/Projects/site/.github/workflow.yml",
            "/Users/me/.Trash/old.pdf",
            "/Users/me/Applications/Example.app/Contents/Resources/Manual.pdf",
            "/Users/me/Pictures/Photos Library.photoslibrary/originals/A/1.heic",
            "/Users/me/Downloads/Plugin.bundle/Contents/Info.plist",
        ]
        for path in hidden {
            XCTAssertFalse(RecentFilePaths.isListable(path, home: home), path)
        }
    }

    func testFoldersReadTheWayFinderNamesThem() {
        func folder(_ path: String) -> String {
            RecentFilePaths.displayFolder(of: path, home: home)
        }
        XCTAssertEqual(folder("/Users/me/Downloads/a.pdf"), "~/Downloads")
        XCTAssertEqual(folder("/Users/me/a.pdf"), "~")
        XCTAssertEqual(folder("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.pdf"), "iCloud Drive")
        XCTAssertEqual(
            folder("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2025/a.pdf"),
            "iCloud Drive/Taxes/2025"
        )
        XCTAssertEqual(
            folder("/Users/me/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents/a.pdf"),
            "iCloud Drive/iBooks"
        )
        XCTAssertEqual(folder("/Users/me/Library/CloudStorage/Dropbox/Photos/a.jpg"), "Dropbox/Photos")
        XCTAssertEqual(
            folder("/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/a.pdf"),
            "GoogleDrive-me@example.com/My Drive"
        )
        XCTAssertEqual(folder("/Volumes/Backup/scan.pdf"), "/Volumes/Backup")
        XCTAssertEqual(folder("/Users/meg/a.pdf"), "/Users/meg")
    }

    func testTypeComesFromSpotlightOrTheExtension() {
        XCTAssertEqual(recent("/Users/me/a", type: "com.adobe.pdf").type, .pdf)
        XCTAssertEqual(recent("/Users/me/a.png").type, .png)
        XCTAssertTrue(recent("/Users/me/a.unknownext").type.conforms(to: .data))
        XCTAssertEqual(recent("/Users/me/Downloads/Q3 report.pdf").name, "Q3 report.pdf")
    }

    func testSymbolsByType() {
        XCTAssertEqual(RecentFilesModule.symbolName(for: .pdf), "doc.richtext")
        XCTAssertEqual(RecentFilesModule.symbolName(for: .jpeg), "photo")
        XCTAssertEqual(RecentFilesModule.symbolName(for: .mpeg4Movie), "film")
        XCTAssertEqual(RecentFilesModule.symbolName(for: .zip), "doc.zipper")
        XCTAssertEqual(RecentFilesModule.symbolName(for: .swiftSource), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(RecentFilesModule.symbolName(for: .plainText), "doc.text")
        XCTAssertEqual(RecentFilesModule.symbolName(for: .data), "doc")
    }

    func testAppNamesLeaveOutTheExtension() {
        XCTAssertEqual(RecentFilePreview.appName("/System/Applications/Preview.app"), "Preview")
        XCTAssertEqual(RecentFilePreview.appName("/nowhere/Some Tool"), "Some Tool")
    }

    func testExcludedFoldersExpandHome() {
        var config = RecentFilesConfig()
        config.excludedFolders = ["~/Downloads", "/Volumes/Backup/", " ", "~"]
        XCTAssertEqual(config.excludedPrefixes(home: home), ["/Users/me/Downloads/", "/Volumes/Backup/", "/Users/me/"])
    }
}

/// Matching and ranking recent files.
final class RecentFilesIndexTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func file(_ path: String, daysAgo: Double = 1) -> RecentFile {
        recent(path, daysAgo: daysAgo, now: now)
    }

    func testWordPrefixNeedsEveryWordToStartAWordOfTheNameOrFolder() {
        let index = RecentFilesIndex(files: [
            file("/Users/me/Documents/Q3 report.pdf"),
            file("/Users/me/Downloads/reporting-tool.zip"),
            file("/Users/me/Projects/report-site/notes.txt"),
            file("/Users/me/Downloads/passport.jpg"),
        ])
        XCTAssertEqual(index.search("rep", mode: .wordPrefix, limit: 10, now: now).map(\.file.name), [
            "Q3 report.pdf", "reporting-tool.zip", "notes.txt",
        ])
        XCTAssertEqual(index.search("q3 doc", mode: .wordPrefix, limit: 10, now: now).map(\.file.name), [
            "Q3 report.pdf",
        ])
        XCTAssertEqual(index.search("port", mode: .wordPrefix, limit: 10, now: now).count, 0)
        XCTAssertEqual(index.search("port", mode: .anywhere, limit: 10, now: now).map(\.file.name), [
            "Q3 report.pdf", "reporting-tool.zip", "passport.jpg", "notes.txt",
        ])
    }

    func testRecentlyUsedFilesBreakTies() {
        let index = RecentFilesIndex(files: [
            file("/Users/me/Downloads/budget-new.xlsx", daysAgo: 0),
            file("/Users/me/Downloads/budget-old.xlsx", daysAgo: 90),
            file("/Users/me/Budget/plan.txt", daysAgo: 0),
        ])
        let ranked = index.search("budget", mode: .wordPrefix, limit: 10, now: now)
        XCTAssertEqual(
            ranked.map(\.file.name),
            ["budget-new.xlsx", "plan.txt", "budget-old.xlsx"],
            "a folder match used today ahead of a name match months old"
        )
        XCTAssertEqual(ranked[0].recency, 1, accuracy: 0.0001)
        XCTAssertLessThan(ranked[2].recency, 0.1)
    }

    func testEmptyQueryIsMostRecentFirst() {
        let index = RecentFilesIndex(files: [file("/Users/me/a.txt", daysAgo: 0), file("/Users/me/b.txt", daysAgo: 7)])
        let listed = index.search("", mode: .anywhere, limit: 5, now: now)
        XCTAssertEqual(listed.map(\.file.name), ["a.txt", "b.txt"])
        XCTAssertEqual(listed[1].recency, 0.5, accuracy: 0.0001)
        XCTAssertEqual(index.search("", mode: .anywhere, limit: 1, now: now).count, 1)
        XCTAssertEqual(index.search("a", mode: .anywhere, limit: 0, now: now).count, 0)
    }

    func testFindsFilesByHashOfTheirPath() {
        let index = RecentFilesIndex(files: [file("/Users/me/a.txt")])
        XCTAssertEqual(index.file(hash: StableID.hash("/Users/me/a.txt"))?.name, "a.txt")
        XCTAssertNil(index.file(hash: "nope"))
        XCTAssertTrue(index.contains(path: "/Users/me/a.txt"))
        XCTAssertFalse(index.contains(path: "/Users/me/b.txt"))
    }
}

/// A fixed list in place of Spotlight, which can be changed while it's watched.
final class FakeRecentFiles: RecentFilesSource, @unchecked Sendable {
    private let lock = NSLock()
    private let initial: Result<[RecentFile], Error>
    private var continuation: AsyncStream<Result<[RecentFile], Error>>.Continuation?
    private var stopCount = 0

    init(_ initial: Result<[RecentFile], Error>) {
        self.initial = initial
    }

    var stops: Int {
        lock.withLock { stopCount }
    }

    func start() -> AsyncStream<Result<[RecentFile], Error>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Result<[RecentFile], Error>.self, bufferingPolicy: .bufferingNewest(1)
        )
        lock.withLock { self.continuation = continuation }
        continuation.yield(initial)
        return stream
    }

    func send(_ files: [RecentFile]) {
        _ = lock.withLock { continuation }?.yield(.success(files))
    }

    func stop() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
            stopCount += 1
        }
    }
}

/// The module over a fake source.
final class RecentFilesModuleTests: XCTestCase {
    private let opened = OpenedURLs()
    private let preview = "/System/Applications/Preview.app"
    private let empty = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: "", systemContext: nil)

    /// Most recently used first, as Spotlight sorts them.
    private let files = [
        recent("/Users/me/Documents/Q3 report.pdf", daysAgo: 0.5, type: "com.adobe.pdf"),
        recent("/Users/me/Downloads/passport.jpg", daysAgo: 2, type: "public.jpeg"),
        recent("/Users/me/Downloads/reporting-tool.zip", daysAgo: 3, type: "public.zip-archive"),
        recent("/Users/me/Projects/report-site/notes.txt", daysAgo: 40, type: "public.plain-text"),
    ]

    private func makeModule(
        _ source: FakeRecentFiles? = nil,
        config: RecentFilesConfig = RecentFilesConfig(),
        bus: EventBus = EventBus(),
        opens: Bool = true
    ) async throws -> RecentFilesModule {
        let opened = opened
        let preview = preview
        let module = RecentFilesModule(
            source: source ?? FakeRecentFiles(.success(files)),
            home: home,
            appForType: { $0.conforms(to: .pdf) ? preview : nil },
            opener: { url in
                opened.append(url)
                return opens
            }
        )
        await module.configDidUpdate(config)
        try await module.initialize(context: ModuleContext(eventBus: bus, loggerFactory: { Log.module($0) }))
        await module.waitForFirstLoad()
        return module
    }

    private func fileRows(_ actions: [any Action]) -> [RecentFilesAction] {
        actions.compactMap { $0 as? RecentFilesAction }.filter { $0.file != nil }
    }

    func testMainSearchListsMatchingFilesForThreeLetters() async throws {
        let module = try await makeModule()
        let listed = await module.provideActions(query: "", scoring: empty)
        XCTAssertEqual(listed.map(\.id.actionName), ["searchFiles"])
        let short = await module.provideActions(query: "re", scoring: empty)
        XCTAssertEqual(fileRows(short).count, 0)

        let rows = await fileRows(module.provideActions(query: "rep", scoring: empty))
        XCTAssertEqual(rows.map(\.title), ["Q3 report.pdf", "reporting-tool.zip", "notes.txt"])
        XCTAssertEqual(rows.map(\.subtitle), ["~/Documents", "~/Downloads", "~/Projects/report-site"])
        XCTAssertTrue(rows.allSatisfy(\.requiresWordPrefixMatch))
        XCTAssertTrue(rows.allSatisfy(\.keywords.isEmpty))
        XCTAssertEqual(rows.map(\.iconName), ["doc.richtext", "doc.zipper", "doc.text"])
        XCTAssertEqual(rows.map(\.appIconPath), [preview, nil, nil])
        XCTAssertEqual(rows[0].id, RecentFilesModule.actionID(for: "/Users/me/Documents/Q3 report.pdf"))
        // Modest, and higher the more recently the file was used.
        XCTAssertTrue(rows.allSatisfy { $0.relevanceScore > 0.3 && $0.relevanceScore <= 0.5 })
        XCTAssertGreaterThan(rows[0].relevanceScore, rows[1].relevanceScore)
        XCTAssertGreaterThan(rows[1].relevanceScore, rows[2].relevanceScore)
    }

    func testRowsFollowTheConfig() async throws {
        var config = RecentFilesConfig()
        config.fileResults = 1
        let module = try await makeModule(config: config)
        let one = await module.provideActions(query: "rep", scoring: empty)
        XCTAssertEqual(fileRows(one).map(\.title), ["Q3 report.pdf"])

        config.fileResults = 0
        await module.configDidUpdate(config)
        let none = await module.provideActions(query: "rep", scoring: empty)
        XCTAssertEqual(none.map(\.id.actionName), ["searchFiles"])

        config = RecentFilesConfig()
        config.enabledActions = ["file"]
        config.excludedFolders = ["~/Downloads"]
        await module.configDidUpdate(config)
        let rows = await module.provideActions(query: "rep", scoring: empty)
        XCTAssertEqual(rows.map(\.title), ["Q3 report.pdf", "notes.txt"])
        let searchID = ActionID("recentFiles/searchFiles")
        let options = await module.provideParameterOptions(for: "file", in: searchID, query: "")
        XCTAssertEqual(options.map(\.label), ["Q3 report.pdf", "notes.txt"])
        let search = await module.action(id: ActionID("recentFiles/searchFiles"))
        XCTAssertNil(search, "not enabled")
    }

    func testRowsResolveByIDAndOpenTheFile() async throws {
        let module = try await makeModule()
        let path = "/Users/me/Downloads/passport.jpg"
        let action = await module.action(id: RecentFilesModule.actionID(for: path))
        XCTAssertEqual(action?.title, "passport.jpg")
        XCTAssertEqual(action?.subtitle, "~/Downloads")
        let result = try await action?.run(with: ParameterValues())
        guard case .dismiss = result else { return XCTFail("expected the picker to close") }
        XCTAssertEqual(opened.urls, [URL(fileURLWithPath: path).absoluteString])

        let missing = await module.action(id: ActionID("recentFiles/file.nope"))
        XCTAssertNil(missing)
        let elsewhere = await module.action(id: ActionID("safari/searchHistory"))
        XCTAssertNil(elsewhere)
    }

    func testSearchOptionsAreRankedByTheModule() async throws {
        let module = try await makeModule()
        let searchID = ActionID("recentFiles/searchFiles")
        let search = await module.action(id: searchID)
        XCTAssertEqual(search?.parameters.first?.rankedByModule, true)

        let all = await module.provideParameterOptions(for: "file", in: searchID, query: "")
        XCTAssertEqual(all.map(\.label), ["Q3 report.pdf", "passport.jpg", "reporting-tool.zip", "notes.txt"])
        XCTAssertEqual(all.first?.id, "/Users/me/Documents/Q3 report.pdf")
        XCTAssertTrue(all.first?.subtitle?.hasPrefix("~/Documents · ") == true)
        XCTAssertEqual(all.first?.iconName, "doc.richtext")
        XCTAssertNotNil(all.first?.makePreview)

        let port = await module.provideParameterOptions(for: "file", in: searchID, query: "port")
        // All inside a word; then by how recently each was used, the folder match last.
        XCTAssertEqual(port.map(\.label), ["Q3 report.pdf", "passport.jpg", "reporting-tool.zip", "notes.txt"])
        XCTAssertEqual(port.first?.labelHighlightRanges?.count, 1)
        let other = await module.provideParameterOptions(for: "page", in: searchID, query: "")
        XCTAssertEqual(other.count, 0)

        _ = try await search?.run(with: ParameterValues(["file": "/Users/me/Downloads/passport.jpg"]))
        XCTAssertEqual(opened.urls, [URL(fileURLWithPath: "/Users/me/Downloads/passport.jpg").absoluteString])
    }

    /// A URI could hand Search Recent Files any path, and opening a script runs it.
    func testOpensOnlyFilesInTheList() async throws {
        let module = try await makeModule()
        let search = await module.action(id: ActionID("recentFiles/searchFiles"))
        do {
            _ = try await search?.run(with: ParameterValues(["file": "/Users/me/Desktop/install.command"]))
            XCTFail("opened a file that isn't recent")
        } catch RecentFilesError.notRecent {}
        XCTAssertEqual(opened.urls, [])
    }

    func testAFileThatWontOpenIsAnError() async throws {
        let module = try await makeModule(opens: false)
        let action = await module.action(id: RecentFilesModule.actionID(for: "/Users/me/Downloads/passport.jpg"))
        do {
            _ = try await action?.run(with: ParameterValues())
            XCTFail("expected an error")
        } catch let RecentFilesError.couldNotOpen(name) {
            XCTAssertEqual(name, "passport.jpg")
        }
    }

    func testSpotlightFailureShowsWhy() async throws {
        let module = try await makeModule(FakeRecentFiles(.failure(RecentFilesError.spotlightUnavailable)))
        let searchID = ActionID("recentFiles/searchFiles")
        let options = await module.provideParameterOptions(for: "file", in: searchID, query: "anything")
        XCTAssertEqual(options.map(\.id), [""])
        XCTAssertEqual(options.first?.label, "Couldn't list recent files")
        let search = await module.action(id: searchID)
        do {
            _ = try await search?.run(with: ParameterValues(["file": ""]))
            XCTFail("expected an error")
        } catch RecentFilesError.spotlightUnavailable {}
    }

    func testChangesAreAnnouncedAndIndexed() async throws {
        let bus = EventBus()
        let (_, stream) = await bus.subscribe()
        let announced = Counter()
        let listener = Task {
            for await event in stream {
                if case .moduleActionsChanged(moduleID: "recentFiles") = event {
                    announced.add()
                }
            }
        }
        defer { listener.cancel() }
        let source = FakeRecentFiles(.success(files))
        let module = try await makeModule(source, bus: bus)
        for _ in 0 ..< 50 where announced.value == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(announced.value, 1, "the first list")

        let opened = recent("/Users/me/Desktop/Lease agreement.pdf", daysAgo: 0, type: "com.adobe.pdf")
        source.send([opened] + files)
        for _ in 0 ..< 50 where announced.value == 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(announced.value, 2)
        let rows = await fileRows(module.provideActions(query: "lease", scoring: empty))
        XCTAssertEqual(rows.map(\.title), ["Lease agreement.pdf"])

        // The same list again is no news.
        source.send([opened] + files)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(announced.value, 2)
    }

    /// Rows the module found for words spread over a name and a folder ("q3" starts a
    /// word of the name, "doc" one of the folder) survive the picker's own scoring.
    func testFileRowsSurviveThePickersScoring() async throws {
        let module = try await makeModule()
        let rows = await module.provideActions(query: "q3 doc", scoring: empty)
        XCTAssertEqual(fileRows(rows).map(\.title), ["Q3 report.pdf"])
        let scoring = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: "q3 doc", systemContext: nil)
        let ranked = ActionScorer.scoreAndRank(
            corpus: rows.map { ScorableAction(action: $0) }, query: "q3 doc", scoring: scoring
        ).0
        XCTAssertEqual(ranked.map(\.id), fileRows(rows).map(\.id))
    }

    func testTeardownStopsWatching() async throws {
        let source = FakeRecentFiles(.success(files))
        let module = try await makeModule(source)
        let loaded = await module.files.count
        XCTAssertEqual(loaded, 4)
        await module.teardown()
        XCTAssertEqual(source.stops, 1)
        let after = await module.files.count
        XCTAssertEqual(after, 0)
    }
}

/// The real Spotlight query, on this Mac's own Recents. Opt-in: what it finds depends on
/// the Mac, and Spotlight may be off on a CI runner.
final class SpotlightRecentFilesLiveTests: XCTestCase {
    func testGathersFinderRecents() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VIBESHED_LIVE_SPOTLIGHT"] == "1",
            "set VIBESHED_LIVE_SPOTLIGHT=1 to query Spotlight"
        )
        let source = SpotlightRecentFiles()
        defer { source.stop() }
        let start = ContinuousClock.now
        var iterator = source.start().makeAsyncIterator()
        let first = await iterator.next()
        let files = try XCTUnwrap(first).get()
        print("Spotlight gathered \(files.count) recent files in \(ContinuousClock.now - start)")
        let home = NSHomeDirectory()
        XCTAssertTrue(files.allSatisfy { RecentFilePaths.isListable($0.path, home: home) })
        XCTAssertEqual(files.map(\.lastUsed), files.map(\.lastUsed).sorted(by: >))
        XCTAssertTrue(files.allSatisfy { $0.contentType != nil })
    }
}
