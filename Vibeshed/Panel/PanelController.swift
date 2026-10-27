import AppKit
import OSLog
import SwiftUI

@MainActor
@Observable
final class PanelController {
    private var panel: FloatingPanel?
    private let pickerState: PickerState
    private let configManager: ConfigManager
    var coordinator: PickerCoordinator?
    @ObservationIgnored private nonisolated(unsafe) var windowCloseObserver: NSObjectProtocol?

    private(set) var isVisible: Bool = false

    /// Whether the overlay is up behind the picker (not suspended). Without it the picker
    /// draws a more solid, sharper-edged panel to stand out from what's behind.
    private(set) var isBackdropShown = false

    /// `appearance.fill`, read live so a config edit restyles the picker as it is.
    var fill: Double {
        configManager.config.appearance.fill
    }

    /// Bumped each time the panel is put on screen. With `isVisible`, it tells work that
    /// outlives an action run whether the picker is still as the run left it.
    @ObservationIgnored private(set) var presentationCount = 0

    /// When the toggle hotkey last hid the picker, as system uptime. Its state is kept for
    /// `picker.resetAfter` seconds from then: reopened sooner, it's where the user left it.
    /// nil once it's shown again, and after every other way of closing it (Escape at the
    /// root, ⌘Escape, a click outside, a run), so the next show starts fresh.
    private var stateKeptSince: TimeInterval?

    /// What kind of load to perform after the show animation completes.
    private enum DeferredLoad {
        case initial
        case refresh
    }

    private var deferredLoad: DeferredLoad?

    /// Backdrop behind the picker (`appearance.overlay`), shown and hidden with it.
    private let overlay = PickerOverlay()
    /// Invalidates older overlay-style observations when a new one starts.
    @ObservationIgnored private var overlayStyleWatch = 0

    init(pickerState: PickerState, configManager: ConfigManager) {
        self.pickerState = pickerState
        self.configManager = configManager
        // A click on the overlay is a click outside the picker: close it as losing focus
        // would (the next open starts fresh), and take the overlay down even if the
        // panel is somehow already gone.
        overlay.onClick = { [weak self] in
            self?.panel?.animateHide()
            self?.overlay.hide()
        }
    }

    deinit {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// When true, the panel will not auto-hide on resignKey.
    /// Reset automatically when the panel hides.
    func setStaysOpenOnResignKey(_ value: Bool) {
        panel?.staysOpenOnResignKey = value
    }

    /// After a Shift run: until the picker hides, an app the action launches or focuses
    /// doesn't close it by taking keyboard focus — the panel takes focus back.
    func holdKeyFocusThroughActions() {
        panel?.holdsKeyFocus = true
    }

    /// Shows the picker where the toggle hotkey left it, if that was within
    /// `picker.resetAfter`, and otherwise on a fresh search. `fresh` always starts
    /// afresh, for an entry point with its own target (a keybinding's parameter step, a
    /// `vibeshed://picker?q=` query).
    func show(fresh: Bool = false) {
        let panel = getOrCreatePanel()

        // Determine load strategy but defer actual heavy work until animation finishes
        if !fresh, keepsHiddenState {
            deferredLoad = .refresh
        } else {
            pickerState.reset()
            coordinator?.clearContext()
            // Show cached results synchronously (fast — just array copy, no async)
            coordinator?.showCachedActionsIfAvailable()
            deferredLoad = .initial
        }
        stateKeptSince = nil

        // Start animation — heavy work fires in onShowAnimationDidComplete
        present(panel)
        isVisible = true
        // A parameter step kept from before: its live preview ended with the hide.
        coordinator?.syncLivePreview()
        Log.picker.debug("Panel shown")
    }

    /// The toggle hotkey's hide: the state stays for a reopen within `picker.resetAfter`.
    func hide() {
        guard let panel, isVisible else { return }
        deferredLoad = nil
        panel.animateHide()
        isVisible = false
        stateKeptSince = ProcessInfo.processInfo.systemUptime
        coordinator?.syncLivePreview()
        Log.picker.debug("Panel hidden")
    }

    /// Re-shows the panel without resetting state. Used when an action's result
    /// needs the picker back (e.g. pushActions).
    func showRetainingState() {
        let panel = getOrCreatePanel()
        deferredLoad = nil
        present(panel)
        isVisible = true
        stateKeptSince = nil
    }

    /// Closes the picker as Escape at the root does — for a run, or a message dismissed —
    /// so the next show starts fresh. The reset itself waits for that show: done now, it
    /// would swap the step or list for an empty one while the panel fades out.
    func close() {
        guard let panel, isVisible else { return }
        deferredLoad = nil
        panel.animateHide()
        isVisible = false
        Log.picker.debug("Panel closed")
    }

    private var keepsHiddenState: Bool {
        guard let stateKeptSince else { return false }
        return configManager.config.picker.keepsState(
            hiddenFor: ProcessInfo.processInfo.systemUptime - stateKeptSince
        )
    }

    /// Fades the overlay out while a live preview (e.g. `theme/switch`) is changing the
    /// desktop behind it, and back in after.
    func setOverlaySuspended(_ suspended: Bool) {
        overlay.setSuspended(suspended)
        if overlay.isShown {
            isBackdropShown = !suspended
        }
    }

    /// Readies the overlay ahead of its first show, now and after every config change
    /// (see `PickerOverlay.prewarm`). Call once the config has loaded.
    func startOverlay() {
        let config = withObservationTracking {
            configManager.config.appearance.activeOverlay
        } onChange: { [weak self] in
            Task { @MainActor in self?.startOverlay() }
        }
        guard let config, let screen = NSScreen.main else { return }
        overlay.prewarm(config, style: overlayStyle(for: config), pickerScreen: screen)
    }

    // MARK: - Private

    /// Centres the panel on the active screen, puts the overlay behind it, and animates
    /// both in (layout is unavoidable sync work before the animation).
    private func present(_ panel: FloatingPanel) {
        presentationCount += 1
        let screen = NSScreen.main
        if let screen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.midY - panel.frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        presentOverlay(behind: panel, on: screen)
        panel.animateShow()
    }

    private func presentOverlay(behind panel: FloatingPanel, on screen: NSScreen?) {
        guard let config = configManager.config.appearance.activeOverlay, let screen else {
            panel.level = .picker
            overlay.hide()
            isBackdropShown = false
            return
        }
        // The overlay covers the menu bar and Dock, so the picker has to sit above it.
        panel.level = .pickerAboveOverlay
        let pickerFrame = panel.frame.insetBy(dx: PickerView.shadowMargin, dy: PickerView.shadowMargin)
        overlay.show(config, style: overlayStyle(for: config), pickerFrame: pickerFrame, on: screen)
        isBackdropShown = true
        watchOverlayStyle()
    }

    private func overlayStyle(for config: AppConfig.OverlayConfig) -> OverlayStyle {
        let palette = ActiveTheme.shared.displayed?.palette
        let accent = palette?.accent ?? ThemeColor(nsColor: .controlAccentColor) ?? .black
        let tint = OverlayStyle.tint(
            for: config.color,
            palette: palette,
            accent: accent,
            isDarkAppearance: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        )
        return OverlayStyle(
            config: config,
            tint: tint,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    /// Restyles the overlay while it's up when what it's drawn from changes: a theme
    /// applied or live-previewed, the config.
    private func watchOverlayStyle() {
        overlayStyleWatch += 1
        let watch = overlayStyleWatch
        withObservationTracking {
            _ = configManager.config.appearance.activeOverlay.map(overlayStyle(for:))
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.overlayStyleWatch == watch, self.overlay.isShown else { return }
                if let config = self.configManager.config.appearance.activeOverlay {
                    self.overlay.restyle(self.overlayStyle(for: config))
                }
                self.watchOverlayStyle()
            }
        }
    }

    private func onShowAnimationDidComplete() {
        guard let load = deferredLoad else { return }
        deferredLoad = nil

        switch load {
        case .initial:
            coordinator?.loadInitialActions()
        case .refresh:
            coordinator?.refreshInPlace()
        }
    }

    private func getOrCreatePanel() -> FloatingPanel {
        if let existing = panel { return existing }

        let appearance = configManager.config.appearance
        let frame = NSRect(
            x: 0,
            y: 0,
            width: appearance.panelWidth + 2 * PickerView.shadowMargin,
            height: appearance.panelHeight + 2 * PickerView.shadowMargin
        )
        let newPanel = FloatingPanel(contentRect: frame)

        newPanel.onEscape = { [weak self] in
            guard let self else { return false }
            return self.pickerState.popMode()
        }

        newPanel.onWillHide = { [weak self] in
            MainActor.assumeIsolated {
                // Every way the panel hides (Escape, focus loss, an action) passes here.
                self?.overlay.hide()
                self?.isVisible = false
                self?.coordinator?.syncLivePreview()
            }
        }

        newPanel.onShowAnimationComplete = { [weak self] in
            MainActor.assumeIsolated {
                self?.onShowAnimationDidComplete()
            }
        }

        newPanel.setSwiftUIContent(
            ThemedPickerWrapper(state: pickerState, panelController: self, appearance: appearance)
        )
        newPanel.followPaletteAppearance()

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newPanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isVisible = false
                self?.stateKeptSince = nil
            }
        }

        panel = newPanel
        return newPanel
    }
}

// MARK: - Themed Wrapper

/// Injects the active palette's PickerTheme into the SwiftUI environment.
/// Needed because NSHostingView content is set once, but the @Observable
/// dependency on ActiveTheme triggers re-renders when the theme changes.
private struct ThemedPickerWrapper: View {
    @Bindable var state: PickerState
    let panelController: PanelController
    let appearance: AppConfig.AppearanceConfig

    var body: some View {
        PickerView(state: state, panelController: panelController, appearance: appearance)
            .environment(\.pickerTheme, PickerTheme.current)
    }
}
