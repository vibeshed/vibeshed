@testable import Vibeshed
import XCTest

/// The shortcuts module without the Shortcuts app: listing output, what search shortcuts
/// output, and the module's rows and searches over a stand-in runner.
final class ShortcutsModuleTests: XCTestCase {
    private static let notesID = "6F1C7C55-7B1E-4C8F-9C0B-111111111111"
    private static let timerID = "6F1C7C55-7B1E-4C8F-9C0B-222222222222"
    private static let mailID = "6F1C7C55-7B1E-4C8F-9C0B-333333333333"

    // MARK: Listing output

    func testListEntries() {
        let output = Data("""
        Find Notes (\(Self.notesID))
        Timer (with sound) (\(Self.timerID))
        not a shortcut line
        Broken (1234)
        """.utf8)
        let entries = ShortcutsCLI.entries(output)
        XCTAssertEqual(entries.map(\.name), ["Find Notes", "Timer (with sound)"])
        XCTAssertEqual(entries.map(\.id), [Self.notesID, Self.timerID])
    }

    // MARK: Run output

    func testOutputFileOrFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vibeshed-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(try ShortcutsCLI.items(at: base.appendingPathComponent("none.txt")), [], "no output")

        let file = base.appendingPathComponent("one.txt")
        try Data("You typed: hi".utf8).write(to: file)
        XCTAssertEqual(try ShortcutsCLI.items(at: file), [Data("You typed: hi".utf8)])

        // A list: a file per item, named after its text, in the order they were written.
        let folder = base.appendingPathComponent("list.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, text) in ["zebra", "apple", "mango"].enumerated() {
            let url = folder.appendingPathComponent("\(text).txt")
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))], ofItemAtPath: url.path
            )
        }
        let items = try ShortcutsCLI.items(at: folder).map { String(bytes: $0, encoding: .utf8) }
        XCTAssertEqual(items, ["zebra", "apple", "mango"])
    }

    // MARK: Search output

    func testDictionariesWithLinks() {
        let output = Data("""
        [{"title": "Plan", "subtitle": "Work", "url": "notes://showNote?identifier=x", "icon": "note.text"},
         {"name": "Invoice", "link": "message:%3Cabc@example.com%3E"},
         {"url": "https://example.com/a"},
         {"subtitle": "no title or link"}]
        """.utf8)
        let results = ShortcutResultParser.results(output)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0], ShortcutResult(
            title: "Plan", subtitle: "Work", url: URL(string: "notes://showNote?identifier=x"), icon: "note.text"
        ))
        XCTAssertEqual(results[1].title, "Invoice")
        XCTAssertEqual(results[1].url?.absoluteString, "message:%3Cabc@example.com%3E")
        XCTAssertEqual(results[2].title, "https://example.com/a", "a link alone is its own title")
    }

    func testItemsUnderAKeyAndOneObjectPerLine() {
        XCTAssertEqual(
            ShortcutResultParser.results(Data(#"{"items": [{"title": "A"}, "B"]}"#.utf8)).map(\.title), ["A", "B"]
        )
        let lines = Data("{\"title\": \"A\", \"text\": \"copy me\"}\n{\"title\": \"B\"}\n".utf8)
        let results = ShortcutResultParser.results(lines)
        XCTAssertEqual(results.map(\.title), ["A", "B"])
        XCTAssertEqual(results[0].text, "copy me")
    }

    func testTextLines() {
        let output = Data("Groceries\n\nhttps://example.com/x\nAgenda:draft\nmailto:a@example.com\n".utf8)
        let results = ShortcutResultParser.results(output)
        XCTAssertEqual(
            results.map(\.title), ["Groceries", "https://example.com/x", "Agenda:draft", "mailto:a@example.com"]
        )
        XCTAssertEqual(results.map { $0.url?.absoluteString }, [
            nil, "https://example.com/x", nil, "mailto:a@example.com",
        ])
        XCTAssertEqual(ShortcutResultParser.results(Data("  \n".utf8)), [])
    }

    func testPickedResultSurvivesItsOptionID() {
        let link = PickedResult(ShortcutResult(title: "A", url: URL(string: "https://example.com/a?b=1")))
        XCTAssertEqual(PickedResult(optionID: link.optionID(index: 3)), link)
        let text = PickedResult(ShortcutResult(title: "Title", text: "a\u{1F}b\nc"))
        XCTAssertEqual(PickedResult(optionID: text.optionID(index: 0)), .text("a\u{1F}b\nc"))
        XCTAssertEqual(PickedResult(ShortcutResult(title: "Only a title")), .text("Only a title"))
        XCTAssertNil(PickedResult(optionID: ""))
    }

    // MARK: Module

    private func module(_ runner: StubRunner, config: ShortcutsConfig = ShortcutsConfig()) async -> ShortcutsModule {
        let module = ShortcutsModule(runner: runner)
        await module.configDidUpdate(config)
        return module
    }

    private static let listed = [
        ShortcutInfo(name: "Find Notes", id: notesID, folder: "Vibeshed"),
        ShortcutInfo(name: "Timer", id: timerID, folder: nil),
        ShortcutInfo(name: "Mail Search", id: mailID, folder: "vibeshed"),
    ]

    func testRunRowsAndSearchRows() async {
        let module = await module(StubRunner(shortcuts: Self.listed))
        let actions = await module.provideParameterOptions(for: "shortcut", in: ActionID("shortcuts/run"), query: "")
        XCTAssertEqual(actions.map(\.label), ["Timer"], "search shortcuts aren't offered to run")

        let rows = await module.actions()
        XCTAssertEqual(rows.map(\.title), ["Run Shortcut", "Find Notes", "Timer", "Mail Search"])
        XCTAssertEqual(rows.map { $0.id.actionName.prefix { $0 != "." } }, ["run", "search", "run", "search"])
        XCTAssertEqual(rows[1].parameters.first?.rankedByModule, true)
    }

    func testExcludedAndNoSearchFolder() async {
        var config = ShortcutsConfig()
        config.searchFolder = ""
        config.excluded = ["Timer"]
        let module = await module(StubRunner(shortcuts: Self.listed), config: config)
        _ = await module.provideParameterOptions(for: "shortcut", in: ActionID("shortcuts/run"), query: "")
        let rows = await module.actions()
        XCTAssertEqual(rows.map(\.title), ["Run Shortcut", "Find Notes", "Mail Search"])
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.id.actionName.hasPrefix("run.") })
    }

    /// A list of dictionaries comes from the tool an item at a time, each as its JSON.
    func testSearchRunsWithTheQueryAndListsItsOutput() async throws {
        let runner = StubRunner(shortcuts: Self.listed, outputs: [
            Self.notesID: [#"{"title":"Plan","url":"https:\/\/example.com\/plan"}"#, #"{"title":"Copy me"}"#],
        ])
        let module = await module(runner)
        let searchID = ShortcutsModule.searchID(for: Self.listed[0])
        let options = await module.provideParameterOptions(for: "result", in: searchID, query: "plan")

        XCTAssertEqual(options.map(\.label), ["Plan", "Copy me"])
        XCTAssertEqual(options.map(\.subtitle), ["example.com", nil])
        let runs = await runner.runs
        XCTAssertEqual(runs.last?.shortcut, Self.notesID)
        XCTAssertEqual(runs.last?.input, "plan")
        XCTAssertEqual(runs.last?.timeout, 10)
        XCTAssertEqual(PickedResult(optionID: options[1].id), .text("Copy me"))
    }

    func testAFailedSearchIsOneRowAndPickingItThrows() async throws {
        let runner = StubRunner(shortcuts: Self.listed, failures: [Self.notesID: "Couldn't find Notes"])
        let module = await module(runner)
        let searchID = ShortcutsModule.searchID(for: Self.listed[0])
        let options = await module.provideParameterOptions(for: "result", in: searchID, query: "x")
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, "")
        XCTAssertEqual(options[0].subtitle, "Couldn't find Notes")

        let found = await module.action(id: searchID)
        let action = try XCTUnwrap(found)
        do {
            _ = try await action.run(with: ["result": ""])
            XCTFail("expected the search's error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Couldn't find Notes")
        }
    }

    func testANewerQueryCancelsTheEarlierRun() async {
        let runner = StubRunner(shortcuts: Self.listed, outputs: [Self.notesID: ["A"]], delays: ["slow": 5])
        let module = await module(runner)
        let searchID = ShortcutsModule.searchID(for: Self.listed[0])
        async let slow = module.provideParameterOptions(for: "result", in: searchID, query: "slow")
        try? await Task.sleep(for: .milliseconds(100))
        let fast = await module.provideParameterOptions(for: "result", in: searchID, query: "fast")
        let slowOptions = await slow
        XCTAssertEqual(fast.map(\.label), ["A"])
        XCTAssertEqual(slowOptions, [], "the cancelled run lists nothing")
    }

    func testRunByNameShowsTextOutput() async throws {
        let runner = StubRunner(shortcuts: Self.listed, outputs: [Self.timerID: ["Timer set", "for 5 minutes\n"]])
        let module = await module(runner)
        let found = await module.action(id: ActionID("shortcuts/run"))
        let action = try XCTUnwrap(found)
        let result = try await action.run(with: ["shortcut": "timer"])
        guard case let .showResult(title, body) = result else {
            return XCTFail("expected the output, got \(result)")
        }
        XCTAssertEqual(title, "Timer")
        XCTAssertEqual(body, "Timer set\nfor 5 minutes", "a list's items a line each")
        let runs = await runner.runs
        XCTAssertNil(runs.last?.input, "a plain run has no input")
        XCTAssertNil(runs.last?.timeout, "and may take as long as it takes")

        do {
            _ = try await action.run(with: ["shortcut": "Nope"])
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? ShortcutsError, .notFound("Nope"))
        }
    }

    func testARowResolvesBeforeTheFirstListing() async throws {
        let module = await module(StubRunner(shortcuts: Self.listed))
        let id = ActionID(module: "shortcuts", name: ShortcutsModule.runPrefix + StableID.hash(Self.timerID))
        let found = await module.action(id: id)
        let action = try XCTUnwrap(found)
        XCTAssertEqual(action.title, "Timer")
        let result = try await action.run(with: .empty)
        guard case .dismiss = result else { return XCTFail("no output closes the picker, got \(result)") }
    }

    func testConfig() {
        XCTAssertTrue(ShortcutsModule.validate(ShortcutsConfig()).isValid)
        var config = ShortcutsConfig()
        config.searchTimeout = 0
        XCTAssertFalse(ShortcutsModule.validate(config).isValid)
    }
}

/// Answers like `shortcuts` would, recording each run.
private actor StubRunner: ShortcutsRunning {
    struct Run {
        let shortcut: String
        let input: String?
        let timeout: TimeInterval?
    }

    let shortcuts: [ShortcutInfo]
    /// Each shortcut's output items.
    let outputs: [String: [String]]
    let failures: [String: String]
    /// Seconds a run with this input takes.
    let delays: [String: Double]
    private(set) var runs: [Run] = []

    init(
        shortcuts: [ShortcutInfo],
        outputs: [String: [String]] = [:],
        failures: [String: String] = [:],
        delays: [String: Double] = [:]
    ) {
        self.shortcuts = shortcuts
        self.outputs = outputs
        self.failures = failures
        self.delays = delays
    }

    func list() async throws -> [ShortcutInfo] {
        shortcuts
    }

    func run(_ shortcut: String, input: String?, timeout: TimeInterval?) async throws -> [Data] {
        runs.append(Run(shortcut: shortcut, input: input, timeout: timeout))
        if let input, let delay = delays[input] {
            try await Task.sleep(for: .seconds(delay))
        }
        if let failure = failures[shortcut] {
            throw ShortcutsError.failed(failure)
        }
        return (outputs[shortcut] ?? []).map { Data($0.utf8) }
    }
}
