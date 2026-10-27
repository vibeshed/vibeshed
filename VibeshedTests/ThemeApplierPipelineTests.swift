@testable import Vibeshed
import XCTest

/// The order and coalescing of `ThemeApplier`'s runs, on recording stand-in targets:
/// a newer preview supersedes (and cancels) older ones, the picker retints first, the
/// targets change together after the slow preparation, and Escape reverts the picker
/// before the targets.
@MainActor
final class ThemeApplierPipelineTests: XCTestCase {
    private actor Journal {
        var entries: [String] = []

        func log(_ entry: String) {
            entries.append(entry)
        }
    }

    /// Records each call; `prepareTime` stands in for a wallpaper render.
    private struct RecordingTarget: ThemeTarget {
        let id: ThemeTargetID
        let journal: Journal
        var prepareTime: Duration = .zero
        var restoreTime: Duration = .zero

        var displayName: String { id.rawValue }
        var supportsPreview: Bool { true }

        func prepare(_ request: ThemeApplyRequest) async {
            guard prepareTime > .zero else { return }
            let slug = request.theme.slug
            await journal.log("prepare \(id.rawValue) \(slug)")
            do {
                try await Task.sleep(for: prepareTime)
                await journal.log("prepared \(id.rawValue) \(slug)")
            } catch {
                await journal.log("prepare cancelled \(id.rawValue) \(slug)")
            }
        }

        func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
            if request.isPreview, Task.isCancelled { return .skipped("superseded") }
            await journal.log("apply \(id.rawValue) \(request.theme.slug)")
            return .applied()
        }

        func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
            let (journal, name, delay) = (journal, id.rawValue, restoreTime)
            return {
                try? await Task.sleep(for: delay)
                await journal.log("restored \(name)")
            }
        }
    }

    private let themes = Array(ThemeCatalog.build(config: ThemeConfig(), generated: nil).themes.prefix(3))
    private let options = ThemeApplier.Options(wallpaper: WallpaperChoice(style: .solid, seed: 0, grain: false))

    private var config: ThemeConfig {
        var config = ThemeConfig()
        config.targets = ["zed", "wallpaper"]
        return config
    }

    private func makeApplier(
        journal: Journal,
        prepareTime: Duration = .zero,
        restoreTime: Duration = .zero
    ) -> ThemeApplier {
        let display = ThemeApplier.Display(
            preview: { info in await journal.log("display \(info?.slug ?? "nil")") },
            commit: { info in await journal.log("commit \(info.slug)") }
        )
        return ThemeApplier(
            targets: [
                RecordingTarget(id: .zed, journal: journal, restoreTime: restoreTime),
                RecordingTarget(id: .wallpaper, journal: journal, prepareTime: prepareTime, restoreTime: restoreTime),
            ],
            display: display
        )
    }

    private func preview(_ applier: ThemeApplier, _ theme: ResolvedTheme, isCurrent: Bool = false) async {
        await applier.preview(theme, config: config, options: options, isCurrent: isCurrent)
    }

    func testFixtureThemes() {
        XCTAssertEqual(Set(themes.map(\.slug)).count, 3)
    }

    /// Arrowing past two themes while the first one's wallpaper renders: the render is
    /// cancelled, the second is skipped, and only the last reaches the targets.
    func testNewerPreviewsSupersedeTheOneInFlight() async throws {
        let journal = Journal()
        let applier = makeApplier(journal: journal, prepareTime: .milliseconds(300))
        let (first, second, last) = (themes[0], themes[1], themes[2])

        let inFlight = Task { await preview(applier, first) }
        try await Task.sleep(for: .milliseconds(80)) // into the first one's render
        let skipped = Task { await preview(applier, second) }
        try await Task.sleep(for: .milliseconds(10))
        await preview(applier, last)
        await inFlight.value
        await skipped.value

        let entries = await journal.entries
        XCTAssertTrue(entries.contains("prepare cancelled wallpaper \(first.slug)"), "\(entries)")
        let applied = entries.filter { $0.hasPrefix("apply") }.sorted()
        XCTAssertEqual(applied, ["apply wallpaper \(last.slug)", "apply zed \(last.slug)"], "never \(second.slug)")
        XCTAssertEqual(entries.last { $0.hasPrefix("display") }, "display \(last.slug)")
    }

    /// The picker retints before anything else, and no target changes until the
    /// wallpaper is ready, so they land together.
    func testPickerFirstThenTargetsTogetherAfterPreparing() async {
        let journal = Journal()
        let applier = makeApplier(journal: journal, prepareTime: .milliseconds(50))
        let theme = themes[0]
        await preview(applier, theme)

        let entries = await journal.entries
        XCTAssertEqual(entries.first, "display \(theme.slug)")
        let prepared = entries.firstIndex(of: "prepared wallpaper \(theme.slug)") ?? .max
        let applies = entries.indices.filter { entries[$0].hasPrefix("apply") }
        XCTAssertEqual(applies.count, 2)
        XCTAssertTrue(applies.allSatisfy { $0 > prepared }, "\(entries)")
    }

    func testApplyCommitsWithTheTargetsAfterPreparing() async {
        let journal = Journal()
        let applier = makeApplier(journal: journal, prepareTime: .milliseconds(30))
        let theme = themes[1]
        _ = await applier.apply(theme, config: config, options: options)

        let entries = await journal.entries
        XCTAssertEqual(Array(entries.prefix(3)), [
            "prepare wallpaper \(theme.slug)", "prepared wallpaper \(theme.slug)", "commit \(theme.slug)",
        ])
        XCTAssertEqual(entries.dropFirst(3).sorted(), ["apply wallpaper \(theme.slug)", "apply zed \(theme.slug)"])
    }

    /// Escape: the picker shows the committed theme again before the (slow) restores finish.
    func testEndingThePreviewRevertsThePickerFirst() async {
        let journal = Journal()
        let applier = makeApplier(journal: journal, restoreTime: .milliseconds(150))
        await preview(applier, themes[0])
        await applier.endPreview(committed: false)

        let entries = await journal.entries
        let cleared = entries.firstIndex(of: "display nil")
        let restored = entries.firstIndex { $0.hasPrefix("restored") }
        XCTAssertNotNil(cleared)
        XCTAssertNotNil(restored)
        XCTAssertLessThan(cleared ?? .max, restored ?? .min, "\(entries)")
        XCTAssertEqual(entries.filter { $0.hasPrefix("restored") }.sorted(), ["restored wallpaper", "restored zed"])
    }

    /// Escape while the first preview still renders: nothing was changed, nothing to restore.
    func testEndingDuringTheFirstPreviewCancelsIt() async throws {
        let journal = Journal()
        let applier = makeApplier(journal: journal, prepareTime: .milliseconds(300))
        let inFlight = Task { await preview(applier, themes[0]) }
        try await Task.sleep(for: .milliseconds(80))
        await applier.endPreview(committed: false)
        await inFlight.value

        let entries = await journal.entries
        XCTAssertFalse(entries.contains { $0.hasPrefix("apply") || $0.hasPrefix("restored") }, "\(entries)")
        XCTAssertEqual(entries.last, "display nil")
    }

    /// The list opens on the applied theme: resting there touches nothing.
    func testRestingOnTheCurrentThemeChangesNothing() async {
        let journal = Journal()
        let applier = makeApplier(journal: journal)
        await preview(applier, themes[0], isCurrent: true)
        let entries = await journal.entries
        XCTAssertEqual(entries, [])
    }

    /// A commit keeps what the preview applied: no restores, and the picker isn't reset.
    func testCommittedPreviewIsKept() async {
        let journal = Journal()
        let applier = makeApplier(journal: journal)
        await preview(applier, themes[0])
        await applier.endPreview(committed: true)
        let entries = await journal.entries
        XCTAssertFalse(entries.contains { $0.hasPrefix("restored") || $0 == "display nil" }, "\(entries)")
    }
}
