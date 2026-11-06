import AppKit
import Foundation
import OSLog

private let log = Log.module("theme")

/// Folder color, two ways:
/// - the system-wide "Icon, widget & folder color" (macOS 26+), set to the palette's
///   `folder` color (default: accent) through `IconAppearance` — the same object System
///   Settings › Appearance saves, so the change is live. Tinted icon styles use it too;
/// - a palette-tinted custom icon on each folder listed under `folders:` in config.
struct FolderColorTarget: ThemeTarget {
    let id = ThemeTargetID.folders
    let displayName = "Folder color"
    var supportsPreview: Bool { true }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        let color = request.palette["folder"] ?? request.palette.accent
        let systemApplied = await IconAppearance.applyTint(color)

        var customized = 0
        if !request.isPreview {
            customized = await Self.tintFolders(request.config.folders, color: color)
        }
        if !systemApplied, customized == 0 {
            return request.config.folders.isEmpty
                ? .skipped("needs macOS 26 or folders listed under theme.folders")
                : .failed("couldn't set folder icons")
        }
        return .applied()
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        guard let saved = await IconAppearance.currentTint() else { return nil }
        return { await IconAppearance.restoreTint(saved) }
    }

    @MainActor
    private static func tintFolders(_ folders: [String], color: ThemeColor) -> Int {
        guard !folders.isEmpty, let icon = tintedFolderIcon(color) else { return 0 }
        var count = 0
        for folder in folders {
            let path = ThemeFiles.expand(folder)
            if NSWorkspace.shared.setIcon(icon, forFile: path, options: []) {
                count += 1
            } else {
                log.warning("Couldn't set folder icon on \(path, privacy: .public)")
            }
        }
        return count
    }

    /// The system folder icon recolored: `.color` blending keeps the icon's shading
    /// (luminance) and takes hue/saturation from the palette; `.destinationIn` then
    /// restores the icon's transparent surroundings.
    @MainActor
    private static func tintedFolderIcon(_ color: ThemeColor) -> NSImage? {
        let size = 512
        let base = NSWorkspace.shared.icon(for: .folder)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let baseImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(baseImage, in: rect)
        context.setBlendMode(.color)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.setBlendMode(.destinationIn)
        context.draw(baseImage, in: rect)
        guard let tinted = context.makeImage() else { return nil }
        return NSImage(cgImage: tinted, size: NSSize(width: size, height: size))
    }
}
