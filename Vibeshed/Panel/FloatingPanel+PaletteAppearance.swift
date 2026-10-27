import AppKit

extension FloatingPanel {
    /// Keeps the panel light or dark with the palette on display (`ActiveTheme`), and
    /// with the system without one. Following the system instead, a previewed light
    /// theme's colors arrived on dark glass, which turned light only when macOS's own
    /// appearance switch landed, a moment later.
    func followPaletteAppearance() {
        withObservationTracking {
            let mode = ActiveTheme.shared.displayed?.palette.mode
            let name: NSAppearance.Name? = mode.map { $0 == .dark ? .darkAqua : .aqua }
            if appearance?.name != name {
                appearance = name.flatMap(NSAppearance.init(named:))
            }
        } onChange: { [weak self] in
            // Called before the change lands: read the new value on the next turn.
            Task { @MainActor in self?.followPaletteAppearance() }
        }
    }
}
