import AppKit
import CoreGraphics
import Foundation

/// What one display's generated wallpaper shows: the canvas a style lays out, the part of it
/// this display covers and the image's pixel size. On its own a display is its whole canvas.
/// A spanning style lays one canvas over the whole arrangement instead, and each display
/// shows its own slice of it, so the picture runs on across the bezels.
struct WallpaperFrame: Sendable, Equatable {
    /// The canvas the style lays out, in canvas coordinates (origin bottom-left, y up).
    let canvas: CGSize
    /// The part of the canvas this image shows.
    let viewport: CGRect
    /// The image's size in pixels.
    let pixels: CGSize
    /// One display's worth of canvas: what a style sized for a single screen fills. The
    /// whole canvas unless spanning, where it's the largest display.
    let display: CGSize
    /// Every display in canvas coordinates, so a spanning style can keep what it focuses on
    /// where it can be seen rather than in the gaps of the arrangement's bounding box.
    let displays: [CGRect]

    /// A whole canvas of `size` pixels: one display, or a thumbnail.
    static func single(_ size: CGSize) -> WallpaperFrame {
        let whole = CGRect(origin: .zero, size: size)
        return WallpaperFrame(canvas: size, viewport: whole, pixels: size, display: size, displays: [whole])
    }

    var spans: Bool {
        viewport.size != canvas
    }

    /// Canvas coordinates to the image's pixels.
    var transform: CGAffineTransform {
        CGAffineTransform(scaleX: pixels.width / viewport.width, y: pixels.height / viewport.height)
            .translatedBy(x: -viewport.minX, y: -viewport.minY)
    }

    /// Everything that sets the picture apart from another frame of the same pixel size,
    /// for the file name.
    var signature: String {
        guard spans else { return "" }
        let numbers = [canvas.width, canvas.height, viewport.minX, viewport.minY, display.width, display.height]
            + displays.flatMap { [$0.minX, $0.minY, $0.width, $0.height] }
        let hash = StableHash.of(numbers.map { String(Int($0.rounded())) }.joined(separator: ","))
        return String(hash & 0xFFFF_FFFF, radix: 16)
    }
}

/// The desktop's displays as AppKit arranges them: frames in global points, with the origin
/// at the main display's bottom-left corner and y up, as in System Settings › Displays.
struct WallpaperLayout: Sendable, Equatable {
    struct Display: Sendable, Equatable {
        /// `NSScreenNumber`, which `setDesktopImageURL` is matched back to.
        let id: Int
        let frame: CGRect
        let backingScale: CGFloat
    }

    let displays: [Display]

    /// The longest side rendered for any display, so a huge one can't produce an
    /// unreasonably large image.
    static let maximumSide: CGFloat = 6144

    /// Pixels per point on `display`: its backing scale, less if it would pass the cap.
    static func pixelScale(_ display: Display) -> CGFloat {
        min(display.backingScale, maximumSide / max(display.frame.width, display.frame.height, 1))
    }

    /// The frame each display's image is drawn in, by display ID. Displays of the same size
    /// get equal frames unless `spanning`.
    func frames(spanning: Bool) -> [Int: WallpaperFrame] {
        guard spanning, displays.count > 1 else {
            return Dictionary(displays.map { display in
                let scale = Self.pixelScale(display)
                let size = CGSize(
                    width: (display.frame.width * scale).rounded(), height: (display.frame.height * scale).rounded()
                )
                return (display.id, WallpaperFrame.single(size))
            }, uniquingKeysWith: { first, _ in first })
        }
        // One canvas over the arrangement's bounding box, at the sharpest display's density.
        let scale = displays.map(Self.pixelScale).max() ?? 1
        let bounds = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let inCanvas = displays.map { display in
            CGRect(
                x: (display.frame.minX - bounds.minX) * scale, y: (display.frame.minY - bounds.minY) * scale,
                width: display.frame.width * scale, height: display.frame.height * scale
            )
        }
        let largest = inCanvas.max { $0.width * $0.height < $1.width * $1.height } ?? inCanvas[0]
        let canvas = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return Dictionary(zip(displays, inCanvas).map { display, viewport in
            let pixelScale = Self.pixelScale(display)
            let pixels = CGSize(
                width: (display.frame.width * pixelScale).rounded(),
                height: (display.frame.height * pixelScale).rounded()
            )
            let frame = WallpaperFrame(
                canvas: canvas, viewport: viewport, pixels: pixels, display: largest.size, displays: inCanvas
            )
            return (display.id, frame)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The displays connected now.
    @MainActor
    static var current: WallpaperLayout {
        WallpaperLayout(displays: NSScreen.screens.compactMap { screen in
            guard let id = screen.displayNumber else { return nil }
            return Display(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor)
        })
    }
}

extension NSScreen {
    /// `NSScreenNumber`: the display's `CGDirectDisplayID`.
    var displayNumber: Int? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}
