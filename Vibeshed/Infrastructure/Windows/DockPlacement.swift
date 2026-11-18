import CoreGraphics
import Foundation

/// Where the Dock sits and whether it hides, as set in System Settings › Desktop & Dock.
struct DockPlacement: Equatable, Sendable {
    enum Edge: String, Sendable {
        case bottom
        case left
        case right
    }

    var edge: Edge
    var autohide: Bool

    /// The Dock's current settings, read from its preferences. They're fresh on every read
    /// (cfprefsd serves them), so a Dock hidden or moved while Vibeshed runs counts at once.
    static func current() -> DockPlacement {
        let domain = "com.apple.dock" as CFString
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool
        return DockPlacement(
            edge: orientation.flatMap(Edge.init(rawValue:)) ?? .bottom,
            autohide: autohide ?? false
        )
    }

    /// The area windows may fill on a screen with full `frame` and `visibleFrame` `visible`
    /// (both AppKit coordinates). While the Dock hides, its edge goes back to the windows:
    /// macOS 27.2 keeps a hidden Dock's whole strip out of `visibleFrame`, so maximize and
    /// the tiles stopped a Dock's width short of that edge. The menu bar's strip stays out.
    func usableFrame(frame: CGRect, visible: CGRect) -> CGRect {
        guard autohide else { return visible }
        var area = visible
        switch edge {
        case .bottom:
            area.size.height = area.maxY - frame.minY
            area.origin.y = frame.minY
        case .left:
            area.size.width = area.maxX - frame.minX
            area.origin.x = frame.minX
        case .right:
            area.size.width = frame.maxX - area.minX
        }
        return area
    }
}
