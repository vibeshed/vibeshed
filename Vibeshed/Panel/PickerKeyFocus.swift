import Foundation

/// Whether the picker panel holds keyboard focus, for keystrokes synthesized for the
/// app the user was in (paste-on-select's ⌘V). The panel doesn't activate Vibeshed, so
/// that app stays frontmost underneath — but an action picked in the picker runs while
/// the panel is still fading out and key, and a ⌘V posted then pastes into the
/// picker's search field. The panel resigns key when its hide orders it out.
@MainActor
final class PickerKeyFocus {
    static let shared = PickerKeyFocus()

    private(set) var isHeld = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Set by `PanelController` as the panel becomes and resigns key.
    func setHeld(_ held: Bool) {
        isHeld = held
        guard !held else { return }
        let released = waiters.values
        waiters.removeAll()
        for waiter in released {
            waiter.resume(returning: true)
        }
    }

    /// Returns `true` once the picker has let go of keyboard focus (at once if it doesn't
    /// hold it), or `false` if it still holds it after `timeout` — it was reopened before
    /// its hide finished, or the action came from a keybinding while it was up.
    func waitUntilReleased(timeout: Duration = .seconds(1)) async -> Bool {
        guard isHeld else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }
}
