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
        let failed = await withEachURL(of: missing, ignoring: .alreadyRegistered) { urls, handler in
            CTFontManagerRegisterFontURLs(urls, scope, true, handler)
        }
        return Outcome(registered: missing.filter { failed[$0] == nil }, failed: failed)
    }

    /// Unregisters the files among `paths` that `activate` registered, in this process or
    /// an earlier one, so their fonts don't outlive them. CoreText can't unregister a
    /// deleted file, so this goes before deleting them. Returns the files unregistered.
    static func deactivate(_ paths: [String], scope: CTFontManagerScope = .session) async -> [String] {
        let registered = paths.filter { CTFontManagerGetScopeForURL(URL(fileURLWithPath: $0) as CFURL) == scope }
        guard !registered.isEmpty else { return [] }
        let failed = await withEachURL(of: registered, ignoring: .notRegistered) { urls, handler in
            CTFontManagerUnregisterFontURLs(urls, scope, handler)
        }
        return registered.filter { failed[$0] == nil }
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

    /// Runs a CoreText (un)registration of `paths`, returning its error code for each one
    /// that failed. An `ignored` error (the file already was what was asked) isn't a failure.
    private static func withEachURL(
        of paths: [String],
        ignoring ignored: CTFontManagerError,
        _ call: (CFArray, @escaping (CFArray, Bool) -> Bool) -> Void
    ) async -> [String: Int] {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        return await withCheckedContinuation { continuation in
            var failed: [String: Int] = [:]
            call(urls as CFArray) { errors, done in
                let errors = errors as? [NSError] ?? []
                for error in errors where error.code != ignored.rawValue {
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
