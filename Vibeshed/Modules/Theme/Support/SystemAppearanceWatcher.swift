import AppKit

/// Calls back whenever the system's light/dark mode changes, whoever changed it: the
/// Auto schedule, System Settings, or Vibeshed itself.
@MainActor
final class SystemAppearanceWatcher {
    private var observation: NSKeyValueObservation?

    /// Nil without an NSApplication (unit tests), where there's no system mode to read.
    init?(handler: @escaping @Sendable () -> Void) {
        guard let app = NSApp else { return nil }
        observation = app.observe(\.effectiveAppearance) { _, _ in handler() }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}
