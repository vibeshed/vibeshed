import Foundation
import OSLog

/// Runs themes through their targets. All work is serialized through one pipeline so a
/// preview, its revert and a commit can never interleave, and previews are coalesced:
/// arrowing quickly through ten themes applies only the one the highlight rests on, and
/// a new highlight cancels the preview still in flight (a wallpaper still rendering).
///
/// Each run goes picker first, then `prepare` (the slow part: rendering a wallpaper),
/// then every target at once, so the desktop changes in one step instead of the apps
/// first and the wallpaper a render later.
actor ThemeApplier {
    struct Result: Sendable {
        let target: String
        let outcome: ThemeTargetOutcome
    }

    static let targets: [any ThemeTarget] = [
        AppearanceTarget(), AccentTarget(), FolderColorTarget(), PointerTarget(), WallpaperTarget(),
        ITermTarget(), GhosttyTarget(), TerminalTarget(), VSCodeTarget(), ZedTarget(), JetBrainsTarget(),
        NeovimTarget(), ClaudeCodeTarget(), BatTarget(), LsdTarget(), MicroTarget(), BtopTarget(), GitHubWebTarget(),
        TemplatesTarget(), HooksTarget(),
    ]

    /// Where Vibeshed's own UI learns the theme on display: `ActiveTheme.shared`, except in tests.
    struct Display: Sendable {
        var preview: @Sendable (ActiveThemeInfo?) async -> Void
        var commit: @Sendable (ActiveThemeInfo) async -> Void

        static let activeTheme = Display(
            preview: { info in await MainActor.run { ActiveTheme.shared.preview(info) } },
            commit: { info in await MainActor.run { ActiveTheme.shared.commit(info) } }
        )
    }

    private let log = Log.module("theme")
    private let allTargets: [any ThemeTarget]
    private let display: Display
    private var pipeline: Task<Void, Never>?
    /// The preview queued or running, cancelled when a newer one (or the end) arrives.
    private var inFlightPreview: Task<Void, Never>?

    /// State captured before the first preview of a `theme/switch` session.
    private struct PreviewSession {
        var restores: [ThemeRestore] = []
        var captured: Set<ThemeTargetID> = []
        var hasApplied = false
    }

    private var previewSession: PreviewSession?
    private var previewGeneration = 0

    /// What to apply beyond the theme itself.
    struct Options: Sendable {
        var wallpaper: WallpaperChoice
        /// Restrict to these targets (e.g. just the wallpaper); nil = every enabled target.
        var only: Set<ThemeTargetID>?
    }

    init(targets: [any ThemeTarget] = ThemeApplier.targets, display: Display = .activeTheme) {
        allTargets = targets
        self.display = display
    }

    // MARK: - Public

    func apply(_ theme: ResolvedTheme, config: ThemeConfig, options: Options) async -> [Result] {
        await enqueue { await self.performApply(theme, config: config, options: options) }.value
    }

    /// Previews `theme`. `isCurrent` means it's what is already applied: until something
    /// else has been previewed, resting on it changes nothing.
    func preview(_ theme: ResolvedTheme, config: ThemeConfig, options: Options, isCurrent: Bool) async {
        previewGeneration += 1
        let generation = previewGeneration
        inFlightPreview?.cancel()
        let task = enqueue {
            await self.performPreview(
                theme, config: config, options: options, isCurrent: isCurrent, generation: generation
            )
        }
        inFlightPreview = task
        await task.value
    }

    /// Ends a preview session: reverts everything it changed unless `committed`. The
    /// picker goes back to the committed theme at once, ahead of the targets' restores.
    func endPreview(committed: Bool) async {
        previewGeneration += 1
        inFlightPreview?.cancel()
        inFlightPreview = nil
        // Queued before the first suspension, so a preview that arrives meanwhile (a new
        // session) runs after this revert rather than being reverted by it.
        let finish = enqueue { await self.finishPreview(committed: committed) }
        if !committed { await display.preview(nil) }
        await finish.value
    }

    static func enabledTargets(
        for theme: ResolvedTheme,
        config: ThemeConfig,
        only: Set<ThemeTargetID>? = nil,
        from targets: [any ThemeTarget] = ThemeApplier.targets
    ) -> [any ThemeTarget] {
        var ids = config.enabledTargets
        // A theme that names a GitHub theme opts into that target unless targets are explicit.
        if config.targets == nil, theme.appOverrides[ThemeTargetID.github.rawValue] != nil {
            ids.insert(.github)
        }
        if let only { ids.formIntersection(only) }
        return targets.filter { ids.contains($0.id) }
    }

    // MARK: - Pipeline

    /// Runs `operation` after everything queued before it.
    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let previous = pipeline
        let task = Task {
            await previous?.value
            return await operation()
        }
        pipeline = Task { _ = await task.value }
        return task
    }

    private func performApply(_ theme: ResolvedTheme, config: ThemeConfig, options: Options) async -> [Result] {
        // A committed preview already left its changes in place; nothing to restore.
        previewSession = nil
        let request = ThemeApplyRequest(theme: theme, config: config, isPreview: false, wallpaper: options.wallpaper)
        let targets = Self.enabledTargets(for: theme, config: config, only: options.only, from: allTargets)
        await prepare(request, targets)
        await display.commit(theme.activeInfo)
        // Hooks go last so they can rely on everything else (e.g. rendered templates).
        var results = await run(request, targets.filter { $0.id != .hooks })
        results += await run(request, targets.filter { $0.id == .hooks })
        for result in results {
            let line = "\(theme.name) → \(result.target): \(String(describing: result.outcome))"
            log.info("\(line, privacy: .public)")
        }
        return results
    }

    private func performPreview(
        _ theme: ResolvedTheme,
        config: ThemeConfig,
        options: Options,
        isCurrent: Bool,
        generation: Int
    ) async {
        // A newer highlight (or the end of the session) superseded this one.
        guard generation == previewGeneration, !Task.isCancelled else { return }
        var session = previewSession ?? PreviewSession()
        // Resting on what's already applied changes nothing — don't touch anything yet.
        if !session.hasApplied, isCurrent {
            previewSession = session
            return
        }
        // The picker first: it's where the user is looking, and it follows the highlight.
        await display.preview(theme.activeInfo)

        let targets = Self.enabledTargets(for: theme, config: config, only: options.only, from: allTargets)
            .filter(\.supportsPreview)
        let uncaptured = targets.filter { !session.captured.contains($0.id) }
        session.restores += await snapshots(uncaptured, config: config)
        session.captured.formUnion(uncaptured.map(\.id))
        previewSession = session

        let request = ThemeApplyRequest(theme: theme, config: config, isPreview: true, wallpaper: options.wallpaper)
        await prepare(request, targets)
        guard generation == previewGeneration, !Task.isCancelled else { return }
        previewSession?.hasApplied = true
        _ = await run(request, targets)
    }

    private func finishPreview(committed: Bool) async {
        guard let session = previewSession else { return }
        previewSession = nil
        guard !committed else { return }
        if session.hasApplied {
            let start = ContinuousClock.now
            // Each restore puts back its own target's state, so they can run side by side.
            await withTaskGroup(of: Void.self) { group in
                for restore in session.restores {
                    group.addTask { await restore() }
                }
            }
            log.debug("Reverted the preview in \(Self.milliseconds(since: start))ms")
        }
        await display.preview(nil)
    }

    // MARK: - Fan-out

    private func prepare(_ request: ThemeApplyRequest, _ targets: [any ThemeTarget]) async {
        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask { await target.prepare(request) }
            }
        }
        log.debug("Prepared \(request.theme.name, privacy: .public) in \(Self.milliseconds(since: start))ms")
    }

    private func run(_ request: ThemeApplyRequest, _ targets: [any ThemeTarget]) async -> [Result] {
        let start = ContinuousClock.now
        let timed = await withTaskGroup(of: (Result, Int).self) { group in
            for target in targets {
                group.addTask {
                    let outcome = await target.apply(request)
                    return (Result(target: target.displayName, outcome: outcome), Self.milliseconds(since: start))
                }
            }
            var results: [(Result, Int)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        // Where the time goes, slowest first (`log stream --level debug`).
        let line = timed.sorted { $0.1 > $1.1 }.map { "\($0.0.target) \($0.1)ms" }.joined(separator: ", ")
        let kind = request.isPreview ? "Previewed" : "Applied"
        log.debug("\(kind, privacy: .public) \(request.theme.name, privacy: .public): \(line, privacy: .public)")
        return timed.map(\.0)
    }

    private func snapshots(_ targets: [any ThemeTarget], config: ThemeConfig) async -> [ThemeRestore] {
        await withTaskGroup(of: ThemeRestore?.self) { group in
            for target in targets {
                group.addTask { await target.snapshot(config: config) }
            }
            var restores: [ThemeRestore] = []
            for await restore in group {
                if let restore { restores.append(restore) }
            }
            return restores
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}
