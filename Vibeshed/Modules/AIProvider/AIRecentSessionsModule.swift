import Foundation
import OSLog
import SwiftUI

/// A module whose sessions `ai/recentSessions` lists together with other vendors'.
protocol AISessionListing: Module {
    /// One row per recent session, each reopening it as the module's own list does.
    func recentSessionActions() async -> [AIAction]
}

/// `ai/recentSessions`: the recent sessions of every loaded AI vendor module in one
/// list, the ones waiting on the user first, then the most recently active.
///
/// The rows are the vendor modules' own (`AISessionListing`), so each vendor's
/// `sources`, `maxResults` and way of reopening a session apply as in its list. The
/// module has nothing to configure: it rides on the vendor modules' sections, and its
/// action stays out of search while none of them is loaded.
actor AIRecentSessionsModule: Module {
    let id = "ai"
    let displayName = "AI Sessions"
    let iconName = "sparkles"
    var isEnabled = true

    static let actionID = ActionID(module: "ai", name: "recentSessions")
    static let parameterID = "session"

    private let listingModules: @Sendable () async -> [any AISessionListing]
    /// The rows behind the options last listed, by option id, so running one doesn't
    /// read every vendor's sessions again.
    private var listedRows: [String: AIAction] = [:]
    private let log = Log.module("ai")

    /// `listingModules` returns the loaded vendor modules.
    init(listingModules: @escaping @Sendable () async -> [any AISessionListing]) {
        self.listingModules = listingModules
    }

    func initialize(context _: ModuleContext) async throws {
        log.info("AI sessions module initialized")
    }

    func provideActions(query _: String, scoring _: ScoringContext) async -> [any Action] {
        let names = await vendorNames()
        guard !names.isEmpty else { return [] }
        return [recentSessionsAction(vendorNames: names)]
    }

    /// Resolves the action for a keybinding or URI even while no vendor module is
    /// loaded (yet, during startup), so a binding to it never reads as broken.
    func action(id: ActionID) async -> (any Action)? {
        guard id == Self.actionID else { return nil }
        return await recentSessionsAction(vendorNames: vendorNames())
    }

    func provideParameterOptions(
        for parameterID: String,
        in actionID: ActionID,
        query _: String
    ) async -> [ParameterOption] {
        guard parameterID == Self.parameterID, actionID == Self.actionID else { return [] }
        let rows = await sessionRows()
        listedRows = Dictionary(rows.map { ($0.id.rawValue, $0) }) { first, _ in first }
        return Self.options(for: rows)
    }

    // MARK: - Sessions

    /// Every loaded vendor's session rows in list order (`ranksBefore`).
    func sessionRows() async -> [AIAction] {
        let vendors = await enabledVendors()
        let rows = await withTaskGroup(of: [AIAction].self) { group in
            for vendor in vendors {
                group.addTask { await vendor.recentSessionActions() }
            }
            var rows: [AIAction] = []
            for await batch in group {
                rows += batch
            }
            return rows
        }
        return rows.sorted(by: Self.ranksBefore)
    }

    /// Waiting on the user first, then the latest activity first. Ties go by id, so
    /// the order doesn't depend on which vendor answered first.
    static func ranksBefore(_ lhs: AIAction, _ rhs: AIAction) -> Bool {
        if lhs.isAwaitingUser != rhs.isAwaitingUser {
            return lhs.isAwaitingUser
        }
        let lhsTime = lhs.sessionTimestamp ?? .distantPast
        let rhsTime = rhs.sessionTimestamp ?? .distantPast
        if lhsTime != rhsTime {
            return lhsTime > rhsTime
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    /// One option per row, keyed by the row's action id. A waiting session leads its
    /// subtitle with what it waits for, as the bell on its icon says it waits.
    static func options(for rows: [AIAction]) -> [ParameterOption] {
        rows.map { row in
            ParameterOption(
                id: row.id.rawValue,
                label: row.title,
                subtitle: row.waitingFor.map { "Waiting for you: \($0) · \(row.subtitle)" }
                    ?? row.subtitle,
                iconName: row.isAwaitingUser ? "bell.badge" : row.iconName,
                keywords: row.keywords,
                makePreview: { AnyView(AIActionPreviewView(action: row)) }
            )
        }
    }

    private func enabledVendors() async -> [any AISessionListing] {
        var enabled: [any AISessionListing] = []
        for vendor in await listingModules() {
            guard await vendor.isEnabled else { continue }
            enabled.append(vendor)
        }
        return enabled
    }

    private func vendorNames() async -> [String] {
        var names: [String] = []
        for vendor in await enabledVendors() {
            await names.append(vendor.displayName)
        }
        return names
    }

    /// The row an option stands for: the one listed with it, or, for a value that
    /// didn't come from this picker session (a URI), the vendors' current rows.
    private func row(forOption optionID: String) async -> AIAction? {
        if let row = listedRows[optionID] {
            return row
        }
        return await sessionRows().first { $0.id.rawValue == optionID }
    }

    // MARK: - Action

    private func recentSessionsAction(vendorNames: [String]) -> AIAction {
        let vendors = vendorNames.isEmpty ? "" : " · \(vendorNames.joined(separator: ", "))"
        return AIAction(
            id: Self.actionID,
            title: "Recent AI Sessions",
            subtitle: "Waiting on you first, then the latest activity\(vendors)",
            iconName: "clock.arrow.circlepath",
            relevanceScore: 0.8,
            keywords: ["ai", "recent", "sessions", "waiting", "attention", "agents"]
                + vendorNames.map { $0.lowercased() },
            parameters: [
                ActionParameter(
                    id: Self.parameterID,
                    label: "Session",
                    type: .dynamicSelection(hint: Self.parameterID),
                    isRequired: true
                ),
            ],
            moduleName: displayName
        ) { [self] values in
            guard let optionID = values[Self.parameterID] else {
                return .showResult(title: "Recent AI Sessions", body: "No session selected")
            }
            guard let row = await row(forOption: optionID) else {
                return .showResult(title: "Session Not Found", body: "That session is no longer listed")
            }
            return try await row.run(with: [:])
        }
    }
}
