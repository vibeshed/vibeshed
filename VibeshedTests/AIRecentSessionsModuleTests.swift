import Foundation
@testable import Vibeshed
import XCTest

/// `ai/recentSessions`: every loaded vendor's sessions in one list, waiting ones first,
/// then the latest activity; picking one reopens it through its vendor's row.
final class AIRecentSessionsModuleTests: XCTestCase {
    private let now = Date()

    // MARK: - Order

    func testWaitingSessionsLeadThenLatestActivityAcrossVendors() async {
        let claude = FakeVendor(id: "anthropic", rows: [
            row("anthropic", "old-waiting", minutesAgo: 90, waitingFor: "permission prompt"),
            row("anthropic", "claude-recent", minutesAgo: 5),
        ])
        let codex = FakeVendor(id: "openai", rows: [
            row("openai", "codex-newest", minutesAgo: 1),
            row("openai", "codex-old", minutesAgo: 60),
        ])
        let module = AIRecentSessionsModule { [claude, codex] }

        let titles = await module.sessionRows().map(\.title)
        XCTAssertEqual(titles, ["old-waiting", "codex-newest", "claude-recent", "codex-old"])
    }

    func testDisabledVendorIsLeftOut() async {
        let claude = FakeVendor(id: "anthropic", rows: [row("anthropic", "claude", minutesAgo: 1)])
        let codex = FakeVendor(id: "openai", rows: [row("openai", "codex", minutesAgo: 2)])
        await codex.setEnabled(false)
        let module = AIRecentSessionsModule { [claude, codex] }

        let titles = await module.sessionRows().map(\.title)
        XCTAssertEqual(titles, ["claude"])
    }

    // MARK: - Options

    func testOptionsSayWhatAWaitingSessionWaitsFor() async throws {
        let waiting = row("anthropic", "Fix the build", minutesAgo: 3, waitingFor: "input needed")
        let idle = row("openai", "Write docs", minutesAgo: 1)
        let module = AIRecentSessionsModule { [FakeVendor(id: "anthropic", rows: [idle, waiting])] }

        let options = await module.provideParameterOptions(
            for: AIRecentSessionsModule.parameterID, in: AIRecentSessionsModule.actionID, query: ""
        )
        XCTAssertEqual(options.map(\.id), [waiting.id.rawValue, idle.id.rawValue])

        let first = try XCTUnwrap(options.first)
        XCTAssertEqual(first.label, "Fix the build")
        XCTAssertEqual(first.iconName, "bell.badge")
        XCTAssertEqual(first.subtitle, "Waiting for you: input needed · \(waiting.subtitle)")
        XCTAssertNotNil(first.makePreview)

        let second = try XCTUnwrap(options.last)
        XCTAssertEqual(second.subtitle, idle.subtitle)
        XCTAssertEqual(second.iconName, idle.iconName)
    }

    func testOtherParametersHaveNoOptions() async {
        let rows = [row("anthropic", "a", minutesAgo: 1)]
        let module = AIRecentSessionsModule { [FakeVendor(id: "anthropic", rows: rows)] }
        let options = await module.provideParameterOptions(
            for: "other", in: AIRecentSessionsModule.actionID, query: ""
        )
        XCTAssertTrue(options.isEmpty)
    }

    // MARK: - Running

    func testPickingAnOptionReopensThatSession() async throws {
        let opened = OpenedSessions()
        let first = row("anthropic", "first", minutesAgo: 1, opened: opened)
        let second = row("openai", "second", minutesAgo: 2, opened: opened)
        let module = AIRecentSessionsModule { [FakeVendor(id: "anthropic", rows: [first, second])] }
        _ = await module.provideParameterOptions(
            for: AIRecentSessionsModule.parameterID, in: AIRecentSessionsModule.actionID, query: ""
        )

        let action = try await recentSessionsAction(of: module)
        let result = try await action.run(with: [AIRecentSessionsModule.parameterID: second.id.rawValue])

        guard case .dismiss = result else { return XCTFail("expected dismiss, got \(result)") }
        XCTAssertEqual(opened.titles, ["second"])
    }

    /// A value from a URI never went through the option list, so the module reads the
    /// vendors' rows to find it.
    func testOptionNotListedThisSessionIsLookedUp() async throws {
        let opened = OpenedSessions()
        let session = row("anthropic", "from a link", minutesAgo: 1, opened: opened)
        let module = AIRecentSessionsModule { [FakeVendor(id: "anthropic", rows: [session])] }

        let action = try await recentSessionsAction(of: module)
        _ = try await action.run(with: [AIRecentSessionsModule.parameterID: session.id.rawValue])

        XCTAssertEqual(opened.titles, ["from a link"])
    }

    func testUnknownSessionReportsItIsGone() async throws {
        let module = AIRecentSessionsModule { [FakeVendor(id: "anthropic", rows: [])] }
        let action = try await recentSessionsAction(of: module)
        let result = try await action.run(with: [AIRecentSessionsModule.parameterID: "anthropic/session.gone"])

        guard case let .showResult(title, _) = result else { return XCTFail("expected a message, got \(result)") }
        XCTAssertEqual(title, "Session Not Found")
    }

    // MARK: - Visibility

    func testActionListsTheLoadedVendorsAndAsksForASession() async throws {
        let module = AIRecentSessionsModule {
            [
                FakeVendor(id: "anthropic", displayName: "Claude", rows: []),
                FakeVendor(id: "openai", displayName: "Codex", rows: []),
            ]
        }
        let actions = await module.provideActions(query: "", scoring: Self.scoring)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(action.id, AIRecentSessionsModule.actionID)
        XCTAssertTrue(action.subtitle.hasSuffix("Claude, Codex"))
        XCTAssertEqual(action.parameters.map(\.id), [AIRecentSessionsModule.parameterID])
        XCTAssertTrue(action.parameters.allSatisfy(\.isRequired))
    }

    /// Without a vendor there's nothing to list, so search leaves the action out, yet a
    /// keybinding to it still resolves (vendors may simply not have loaded yet).
    func testWithoutVendorsTheActionIsHiddenButResolvable() async {
        let module = AIRecentSessionsModule { [] }
        let actions = await module.provideActions(query: "", scoring: Self.scoring)
        XCTAssertTrue(actions.isEmpty)
        let resolved = await module.action(id: AIRecentSessionsModule.actionID)
        XCTAssertEqual(resolved?.id, AIRecentSessionsModule.actionID)
        let other = await module.action(id: ActionID(module: "ai", name: "other"))
        XCTAssertNil(other)
    }

    // MARK: - Helpers

    private func recentSessionsAction(of module: AIRecentSessionsModule) async throws -> any Action {
        let action = await module.action(id: AIRecentSessionsModule.actionID)
        return try XCTUnwrap(action)
    }

    private static let scoring = ScoringContext(usageCounts: [:], lastUsedDates: [:], query: "", systemContext: nil)

    private func row(
        _ vendor: String,
        _ title: String,
        minutesAgo: Double,
        waitingFor: String? = nil,
        opened: OpenedSessions? = nil
    ) -> AIAction {
        let session = AISession(
            sessionID: "\(vendor)-\(title)",
            source: AnthropicProvider.claudeCode,
            title: title,
            project: "/tmp/project",
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            waitingFor: waitingFor
        )
        return AIAction.forSession(
            session,
            module: AIModuleIdentity(id: vendor, displayName: vendor),
            namePrefix: "session",
            relevanceScore: 0.5
        ) {
            opened?.record(title)
        }
    }
}

/// A vendor module serving fixed rows.
private actor FakeVendor: AISessionListing {
    let id: String
    let displayName: String
    let iconName = "brain"
    var isEnabled = true
    private let rows: [AIAction]

    init(id: String, displayName: String? = nil, rows: [AIAction]) {
        self.id = id
        self.displayName = displayName ?? id
        self.rows = rows
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func initialize(context _: ModuleContext) async throws {}

    func provideActions(query _: String, scoring _: ScoringContext) async -> [any Action] {
        rows
    }

    func recentSessionActions() -> [AIAction] {
        rows
    }
}

/// Titles of the sessions the rows' open handlers were called for.
private final class OpenedSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [String] = []

    var titles: [String] {
        lock.withLock { opened }
    }

    func record(_ title: String) {
        lock.withLock { opened.append(title) }
    }
}
