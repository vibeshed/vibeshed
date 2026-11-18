import AppKit
import CoreGraphics

enum Anchor: String, Codable, Sendable {
    case left
    case right
    case top
    case bottom
    case center
}

enum WindowSizing {
    // MARK: - Coordinate Conversion

    /// The screen's area for windows in CG coordinates (top-left origin): its `visibleFrame`,
    /// plus the Dock's edge while the Dock hides (see `DockPlacement.usableFrame`).
    static func visibleFrameCG(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let visible = DockPlacement.current().usableFrame(frame: screen.frame, visible: screen.visibleFrame)
        let y = primaryHeight - visible.origin.y - visible.height
        return CGRect(x: visible.origin.x, y: y, width: visible.width, height: visible.height)
    }

    /// A screen's full frame (menu bar and Dock areas included) in CG top-left-origin
    /// coordinates.
    static func frameCG(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        return CGRect(x: frame.origin.x, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Converts a CG top-left-origin frame (as used by AX/CGWindowList/WindowInfo.frame) back
    /// into AppKit bottom-left-origin coordinates suitable for `NSWindow.setFrame(_:display:)`.
    /// Self-inverse of the flip in `visibleFrameCG` (same formula, same reference height).
    static func appKitFrame(fromCG cgFrame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = primaryHeight - cgFrame.origin.y - cgFrame.height
        return CGRect(x: cgFrame.origin.x, y: y, width: cgFrame.width, height: cgFrame.height)
    }

    // MARK: - Usable Area

    /// Returns the usable area of the screen after applying padding.
    static func usableArea(screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        CGRect(
            x: screenFrame.origin.x + padding.left,
            y: screenFrame.origin.y + padding.top,
            width: screenFrame.width - padding.left - padding.right,
            height: screenFrame.height - padding.top - padding.bottom
        )
    }

    // MARK: - Stop Resolution

    static func resolveStop(_ stop: SizeStop, screenDimension: Double) -> Double {
        switch stop.unit {
        case .percent:
            screenDimension * stop.value / 100.0
        case .pixels:
            stop.value
        }
    }

    // MARK: - Nearest Stop

    static func nearestStopIndex(
        currentValue: Double,
        resolvedStops: [Double],
        tolerance: Double = 5.0
    ) -> Int? {
        var bestIndex: Int?
        var bestDelta = Double.greatestFiniteMagnitude
        for (index, stop) in resolvedStops.enumerated() {
            let delta = abs(currentValue - stop)
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        guard let index = bestIndex, bestDelta <= tolerance else { return nil }
        return index
    }

    // MARK: - Cycle Horizontal

    static func cycleHorizontal(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        stops: [SizeStop],
        anchor: Anchor
    ) -> CGRect {
        guard !stops.isEmpty else { return currentFrame }
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        // Each stop loses half the gap as a margin on its non-anchored (inner) edge, so two
        // windows cycled to complementary left/right stops end up separated by exactly `gap`,
        // matching tileLeft/tileRight's convention. Stops and matching both use this
        // gap-adjusted value so cycling still advances correctly through the stop list.
        let halfGap = padding.gap / 2.0
        let resolved = stops.map { max(resolveStop($0, screenDimension: area.width) - halfGap, 0) }

        let currentWidth = currentFrame.width
        let matchIndex = nearestStopIndex(currentValue: currentWidth, resolvedStops: resolved)
        let nextIndex: Int = if let match = matchIndex {
            (match + 1) % resolved.count
        } else {
            0
        }

        let newWidth = resolved[nextIndex]
        let newHeight = currentFrame.height

        let newX: Double = switch anchor {
        case .left:
            area.origin.x
        case .right:
            area.maxX - newWidth
        default:
            area.origin.x
        }

        return CGRect(x: newX, y: currentFrame.origin.y, width: newWidth, height: newHeight)
    }

    // MARK: - Cycle Vertical

    static func cycleVertical(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        stops: [SizeStop],
        anchor: Anchor
    ) -> CGRect {
        guard !stops.isEmpty else { return currentFrame }
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        // See cycleHorizontal: half the gap is reserved on the non-anchored (inner) edge.
        let halfGap = padding.gap / 2.0
        let resolved = stops.map { max(resolveStop($0, screenDimension: area.height) - halfGap, 0) }

        let currentHeight = currentFrame.height
        let matchIndex = nearestStopIndex(currentValue: currentHeight, resolvedStops: resolved)
        let nextIndex: Int = if let match = matchIndex {
            (match + 1) % resolved.count
        } else {
            0
        }

        let newHeight = resolved[nextIndex]
        let newWidth = currentFrame.width

        let newY: Double = switch anchor {
        case .top:
            area.origin.y
        case .bottom:
            area.maxY - newHeight
        default:
            area.origin.y
        }

        return CGRect(x: currentFrame.origin.x, y: newY, width: newWidth, height: newHeight)
    }

    // MARK: - Maximize

    static func maximize(screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        usableArea(screenFrame: screenFrame, padding: padding)
    }

    // MARK: - Center

    static func center(currentSize: CGSize, screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let x = area.origin.x + (area.width - currentSize.width) / 2.0
        let y = area.origin.y + (area.height - currentSize.height) / 2.0
        return CGRect(x: x, y: y, width: currentSize.width, height: currentSize.height)
    }

    // MARK: - Tile

    static func tileLeft(screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let halfWidth = (area.width - padding.gap) / 2.0
        return CGRect(x: area.origin.x, y: area.origin.y, width: halfWidth, height: area.height)
    }

    static func tileRight(screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let halfWidth = (area.width - padding.gap) / 2.0
        let x = area.origin.x + halfWidth + padding.gap
        return CGRect(x: x, y: area.origin.y, width: halfWidth, height: area.height)
    }

    static func tileTop(screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let halfHeight = (area.height - padding.gap) / 2.0
        return CGRect(x: area.origin.x, y: area.origin.y, width: area.width, height: halfHeight)
    }

    static func tileBottom(screenFrame: CGRect, padding: PaddingConfig) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let halfHeight = (area.height - padding.gap) / 2.0
        let y = area.origin.y + halfHeight + padding.gap
        return CGRect(x: area.origin.x, y: y, width: area.width, height: halfHeight)
    }

    // MARK: - Enlarge/Shrink

    /// Determines the horizontal anchor of a window based on its position relative to screen center.
    /// Windows whose midX is within `tolerance` of the area midX are treated as centered.
    static func detectHorizontalAnchor(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        tolerance: Double = 5.0
    ) -> Anchor {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let delta = currentFrame.midX - area.midX
        if abs(delta) <= tolerance { return .center }
        return delta < 0 ? .left : .right
    }

    /// Determines the vertical anchor of a window based on its position relative to screen center.
    /// Windows whose midY is within `tolerance` of the area midY are treated as centered.
    static func detectVerticalAnchor(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        tolerance: Double = 5.0
    ) -> Anchor {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let delta = currentFrame.midY - area.midY
        if abs(delta) <= tolerance { return .center }
        return delta < 0 ? .top : .bottom
    }

    static func enlargeHorizontal(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        step: SizeStop
    ) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let resolvedStep = resolveStop(step, screenDimension: area.width)
        let anchor = detectHorizontalAnchor(currentFrame: currentFrame, screenFrame: screenFrame, padding: padding)

        let newWidth = min(currentFrame.width + resolvedStep, area.width)
        let newHeight = currentFrame.height

        let newX: Double = switch anchor {
        case .left:
            area.origin.x
        case .right:
            area.maxX - newWidth
        case .center:
            area.midX - newWidth / 2.0
        default:
            currentFrame.origin.x
        }

        return CGRect(x: newX, y: currentFrame.origin.y, width: newWidth, height: newHeight)
    }

    static func shrinkHorizontal(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        step: SizeStop
    ) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let resolvedStep = resolveStop(step, screenDimension: area.width)
        let anchor = detectHorizontalAnchor(currentFrame: currentFrame, screenFrame: screenFrame, padding: padding)

        let newWidth = max(currentFrame.width - resolvedStep, resolvedStep)
        let newHeight = currentFrame.height

        let newX: Double = switch anchor {
        case .left:
            area.origin.x
        case .right:
            area.maxX - newWidth
        case .center:
            area.midX - newWidth / 2.0
        default:
            currentFrame.origin.x
        }

        return CGRect(x: newX, y: currentFrame.origin.y, width: newWidth, height: newHeight)
    }

    static func enlargeVertical(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        step: SizeStop
    ) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let resolvedStep = resolveStop(step, screenDimension: area.height)
        let anchor = detectVerticalAnchor(currentFrame: currentFrame, screenFrame: screenFrame, padding: padding)

        let newWidth = currentFrame.width
        let newHeight = min(currentFrame.height + resolvedStep, area.height)

        let newY: Double = switch anchor {
        case .top:
            area.origin.y
        case .bottom:
            area.maxY - newHeight
        case .center:
            area.midY - newHeight / 2.0
        default:
            currentFrame.origin.y
        }

        return CGRect(x: currentFrame.origin.x, y: newY, width: newWidth, height: newHeight)
    }

    static func shrinkVertical(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        step: SizeStop
    ) -> CGRect {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let resolvedStep = resolveStop(step, screenDimension: area.height)
        let anchor = detectVerticalAnchor(currentFrame: currentFrame, screenFrame: screenFrame, padding: padding)

        let newWidth = currentFrame.width
        let newHeight = max(currentFrame.height - resolvedStep, resolvedStep)

        let newY: Double = switch anchor {
        case .top:
            area.origin.y
        case .bottom:
            area.maxY - newHeight
        case .center:
            area.midY - newHeight / 2.0
        default:
            currentFrame.origin.y
        }

        return CGRect(x: currentFrame.origin.x, y: newY, width: newWidth, height: newHeight)
    }

    // MARK: - Toggle Maximize/Restore

    static func isMaximized(
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig,
        tolerance: Double = 5.0
    ) -> Bool {
        let area = usableArea(screenFrame: screenFrame, padding: padding)
        let widthMatch = abs(currentFrame.width - area.width) <= tolerance
        let heightMatch = abs(currentFrame.height - area.height) <= tolerance
        let xMatch = abs(currentFrame.origin.x - area.origin.x) <= tolerance
        let yMatch = abs(currentFrame.origin.y - area.origin.y) <= tolerance
        return widthMatch && heightMatch && xMatch && yMatch
    }

    static func toggleMaximize(
        windowID: Int,
        currentFrame: CGRect,
        screenFrame: CGRect,
        padding: PaddingConfig
    ) async -> CGRect {
        if isMaximized(currentFrame: currentFrame, screenFrame: screenFrame, padding: padding) {
            if let saved = await MaximizeMemory.shared.restore(windowID) {
                return saved
            }
            // Fallback: center at 80% if no saved frame
            let area = usableArea(screenFrame: screenFrame, padding: padding)
            let restoreWidth = area.width * 0.8
            let restoreHeight = area.height * 0.8
            let x = area.origin.x + (area.width - restoreWidth) / 2.0
            let y = area.origin.y + (area.height - restoreHeight) / 2.0
            return CGRect(x: x, y: y, width: restoreWidth, height: restoreHeight)
        } else {
            await MaximizeMemory.shared.save(currentFrame, for: windowID)
            return maximize(screenFrame: screenFrame, padding: padding)
        }
    }
}

/// Remembers each window's pre-maximize frame so a second toggle can restore it.
/// Window actions run off the `WindowModule` actor, so this owns its own isolation.
actor MaximizeMemory {
    static let shared = MaximizeMemory()

    private var frames: [Int: CGRect] = [:]

    func save(_ frame: CGRect, for windowID: Int) {
        frames[windowID] = frame
    }

    func restore(_ windowID: Int) -> CGRect? {
        frames.removeValue(forKey: windowID)
    }
}
