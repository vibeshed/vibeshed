import Foundation

/// Decides when a highlighted option's live preview goes out to its module.
///
/// Arrowing waits for the highlight to rest for `selectionDelay`. Typing a filter moves
/// the highlight to every intermediate top match ("l" → Lupine on the way to "latte"),
/// so a preview also waits until the typing has paused for `typingPause`. Only the
/// latest option is ever delivered: scheduling another one replaces the pending one,
/// and coming back to the option already delivered drops it.
@MainActor
final class LivePreviewScheduler {
    struct Timing: Sendable {
        var selectionDelay: Duration
        var typingPause: Duration

        static let standard = Timing(selectionDelay: .milliseconds(160), typingPause: .milliseconds(350))
    }

    let timing: Timing
    private(set) var pendingOptionID: String?
    private(set) var deliveredOptionID: String?
    private var pendingDelivery: (@Sendable () async -> Void)?
    private var lastFilterEdit: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?

    init(timing: Timing = .standard) {
        self.timing = timing
    }

    /// Previews `optionID` once the highlight and the typing have settled.
    func schedule(_ optionID: String, deliver: @escaping @Sendable () async -> Void) {
        guard optionID != pendingOptionID else { return }
        guard optionID != deliveredOptionID else {
            cancelPending()
            return
        }
        pendingOptionID = optionID
        pendingDelivery = deliver
        restartTimer()
    }

    /// A keystroke in the parameter field: the highlight is about to follow the filter,
    /// so the pending preview waits for the typing to pause.
    func filterEdited() {
        lastFilterEdit = .now
        if pendingOptionID != nil { restartTimer() }
    }

    /// Forgets everything: the preview session ended.
    func reset() {
        cancelPending()
        deliveredOptionID = nil
        lastFilterEdit = nil
    }

    /// How long to wait from now: the selection delay, or the rest of the typing pause
    /// if that runs longer.
    static func delay(_ timing: Timing, sinceFilterEdit elapsed: Duration?) -> Duration {
        guard let elapsed else { return timing.selectionDelay }
        return max(timing.selectionDelay, timing.typingPause - elapsed)
    }

    private func restartTimer() {
        timer?.cancel()
        let delay = Self.delay(timing, sinceFilterEdit: lastFilterEdit.map { .now - $0 })
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        guard let optionID = pendingOptionID, let deliver = pendingDelivery else { return }
        pendingOptionID = nil
        pendingDelivery = nil
        timer = nil
        deliveredOptionID = optionID
        await deliver()
    }

    private func cancelPending() {
        timer?.cancel()
        timer = nil
        pendingOptionID = nil
        pendingDelivery = nil
    }
}
