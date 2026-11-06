import AppKit
import Foundation

/// System Settings › Appearance › Liquid Glass (macOS 27): the tint of translucent surfaces,
/// from clear to tinted. Set through AppKit's own entry points for the setting, Swift SPI on
/// `NSGlassEffectView.Legibility` (`systemLegibility()`, `setSystemLegibility(_:completionHandler:)`),
/// which write the global preferences and move every app over. They're looked up with
/// dlsym, so nothing breaks where they don't exist.
///
/// `Legibility` is a resilient enum, passed and returned by address. Its layout, read back
/// on macOS 27.2: a `Float` payload, then a case byte (0 = `.tintAmount(Float)`, 1 = one of
/// the payload-free `.standard` / `.increased`), and for `Legibility?` one more byte (0 =
/// some). Other cases are kept as raw bytes so they can be put back as they were.
@MainActor
enum LiquidGlass {
    /// A setting as the stored form `ThemedSystemSetting` compares: `tint:0.45523807` for a
    /// tint amount (Float's exact description), `raw:<hex>` for any other case.
    struct Setting: Equatable {
        var bytes: [UInt8]

        init(tint: Double) {
            bytes = withUnsafeBytes(of: Float(tint)) { Array($0) } + [0]
        }

        init?(stored: String) {
            if stored.hasPrefix("tint:"), let tint = Float(stored.dropFirst(5)) {
                bytes = withUnsafeBytes(of: tint) { Array($0) } + [0]
                return
            }
            let hex = Array(stored.dropFirst(4))
            guard stored.hasPrefix("raw:"), hex.count == 10 else { return nil }
            let parsed = stride(from: 0, to: 10, by: 2).compactMap { UInt8(String(hex[$0 ... $0 + 1]), radix: 16) }
            guard parsed.count == 5 else { return nil }
            bytes = parsed
        }

        fileprivate init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var tint: Float? {
            bytes[4] == 0 ? bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) } : nil
        }

        var stored: String {
            tint.map { "tint:\($0)" } ?? "raw:" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Big enough to come back by address (more than four registers), the way AppKit
    /// returns `Legibility`; only its first five bytes are written.
    private struct Returned {
        var words: (UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0)
    }

    private typealias GetFunction = @convention(thin) () -> Returned
    private typealias SetFunction = @convention(thin) (UnsafeRawPointer, @escaping () -> Void) -> Void

    private static let getSymbol = "$sSo17NSGlassEffectViewC6AppKitE10LegibilityO06systemF0AEyFZ"
    private static let setSymbol =
        "$sSo17NSGlassEffectViewC6AppKitE10LegibilityO09setSystemF0_17completionHandleryAESg_yyctFZ"

    /// The layout above is what macOS 27 has; earlier systems had a different setting.
    private static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0,
                                                                                 patchVersion: 0))
    }

    static func current() -> Setting? {
        guard isSupported, let symbol = appKitSymbol(getSymbol) else { return nil }
        let returned = unsafeBitCast(symbol, to: GetFunction.self)()
        let bytes = withUnsafeBytes(of: returned) { Array($0.prefix(5)) }
        // A case byte other than 0 or 1 means the layout isn't the one described above.
        return bytes[4] <= 1 ? Setting(bytes: bytes) : nil
    }

    /// Sets it, and confirms by reading it back.
    static func set(_ setting: Setting) -> Bool {
        guard isSupported, current() != nil, let symbol = appKitSymbol(setSymbol) else { return false }
        // `Legibility?`: the enum's five bytes, then 0 for `.some`.
        let argument = setting.bytes + [0, 0, 0]
        argument.withUnsafeBytes { buffer in
            unsafeBitCast(symbol, to: SetFunction.self)(buffer.baseAddress!) {}
        }
        return current() == setting
    }

    /// Whether Reduce Transparency is on, which hides the glass and so the setting.
    static var isOverridden: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private static func appKitSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY).flatMap { dlsym($0, name) }
    }
}
