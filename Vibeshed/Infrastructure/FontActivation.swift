import CoreText
import Foundation

/// Makes fonts usable as soon as they're installed. fontd, which serves fonts to every
/// app, notices files added to ~/Library/Fonts on its own — unless that folder didn't
/// exist when it started. A new account has none until Homebrew makes one, and then
/// nothing put there shows up in any app until the next login.
enum FontActivation {
    struct Outcome: Equatable {
        /// Files registered with CoreText.
        var registered: [String] = []
        /// Files that couldn't be registered, with CoreText's error code (`CTFontManagerError`).
        var failed: [String: Int] = [:]
    }

    /// Registers the font files among `paths` that are on disk but that no app sees yet.
    /// With `.session`, every app sees them until logout; by the next login, fontd finds
    /// them in their folder on its own.
    static func activate(_ paths: [String], scope: CTFontManagerScope = .session) async -> Outcome {
        let missing = unlisted(paths, available: availableFontPaths())
        guard !missing.isEmpty else { return Outcome() }
        let failed = await register(missing, scope: scope)
        return Outcome(registered: missing.filter { failed[$0] == nil }, failed: failed)
    }

    /// The `paths` that exist but aren't among the `available` font files.
    static func unlisted(
        _ paths: [String],
        available: Set<String>,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        paths.filter { !available.contains($0) && exists($0) }
    }

    /// The files of every font apps can use. CoreText lists a URL per face, naming the
    /// face in the fragment, so this keeps just the paths.
    static func availableFontPaths() -> Set<String> {
        Set((CTFontManagerCopyAvailableFontURLs() as? [URL] ?? []).map(\.path))
    }

    /// Registers `paths`, returning CoreText's error code for each one that failed. A file
    /// that's already registered in `scope` hasn't failed.
    private static func register(_ paths: [String], scope: CTFontManagerScope) async -> [String: Int] {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        return await withCheckedContinuation { continuation in
            var failed: [String: Int] = [:]
            CTFontManagerRegisterFontURLs(urls as CFArray, scope, true) { errors, done in
                let errors = errors as? [NSError] ?? []
                for error in errors where error.code != CTFontManagerError.alreadyRegistered.rawValue {
                    for url in error.userInfo[kCTFontManagerErrorFontURLsKey as String] as? [URL] ?? [] {
                        failed[url.path] = error.code
                    }
                }
                if done { continuation.resume(returning: failed) }
                return true
            }
        }
    }
}
