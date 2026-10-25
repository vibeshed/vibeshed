import Foundation

/// A formula or cask as `brew info --json=v2` describes it: what the install and
/// uninstall pickers show for each package.
struct HomebrewPackage: Sendable, Equatable {
    struct Notice: Sendable, Equatable {
        /// Homebrew's reason, e.g. `discontinued`, `unmaintained`, or free text.
        let reason: String?
        let replacement: String?
    }

    let token: String
    /// Tap-qualified token (`user/tap/name`); the same as `token` for core packages.
    let fullToken: String
    let isCask: Bool
    /// Cask app names, e.g. "Mozilla Firefox". Formulae have none.
    let names: [String]
    let description: String?
    let homepage: String?
    /// Latest available version.
    let version: String?
    let installedVersion: String?
    /// A formula brew pulled in for another one rather than installed by name.
    let isInstalledAsDependency: Bool
    let isOutdated: Bool
    let isPinned: Bool
    /// The cask's app updates itself, so `brew upgrade` leaves it alone.
    let autoUpdates: Bool
    let isKegOnly: Bool
    let license: String?
    let dependencies: [String]
    let conflicts: [String]
    /// Where the cask's `app` artifacts install, e.g. `/Applications/Firefox.app`.
    let appPaths: [String]
    /// Where the cask's `font` artifacts install, e.g. `~/Library/Fonts/FiraCode-Bold.ttf`.
    let fontPaths: [String]
    let caveats: String?
    let tap: String?
    let deprecation: Notice?
    let disabling: Notice?
    /// Installed formulae that depend on this one. Only known for installed listings.
    var requiredBy: [String] = []

    var isInstalled: Bool {
        installedVersion != nil
    }

    var displayName: String {
        names.first ?? token
    }

    /// The first of `appPaths` present on disk.
    var existingAppPath: String? {
        appPaths.first { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Parsing

extension HomebrewPackage {
    /// Parses `brew info --json=v2` output. Malformed JSON yields no packages.
    static func parse(_ json: Data) -> [HomebrewPackage] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        let formulae = root["formulae"] as? [[String: Any]] ?? []
        let casks = root["casks"] as? [[String: Any]] ?? []
        return formulae.compactMap(formula) + casks.compactMap(cask)
    }

    /// Fills each package's `requiredBy` from the dependencies of the others.
    static func linkingDependents(_ packages: [HomebrewPackage]) -> [HomebrewPackage] {
        var dependents: [String: [String]] = [:]
        for package in packages {
            for dependency in package.dependencies {
                dependents[dependency, default: []].append(package.token)
            }
        }
        return packages.map { package in
            var linked = package
            linked.requiredBy = dependents[package.token] ?? dependents[package.fullToken] ?? []
            return linked
        }
    }

    private static func formula(_ json: [String: Any]) -> HomebrewPackage? {
        guard let name = json["name"] as? String else { return nil }
        let installed = (json["installed"] as? [[String: Any]])?.last
        return HomebrewPackage(
            token: name,
            fullToken: json["full_name"] as? String ?? name,
            isCask: false,
            names: [],
            description: nonEmpty(json["desc"]),
            homepage: nonEmpty(json["homepage"]),
            version: (json["versions"] as? [String: Any])?["stable"] as? String,
            installedVersion: installed?["version"] as? String,
            isInstalledAsDependency: installed?["installed_on_request"] as? Bool == false,
            isOutdated: json["outdated"] as? Bool ?? false,
            isPinned: json["pinned"] as? Bool ?? false,
            autoUpdates: false,
            isKegOnly: json["keg_only"] as? Bool ?? false,
            license: nonEmpty(json["license"]),
            dependencies: json["dependencies"] as? [String] ?? [],
            conflicts: json["conflicts_with"] as? [String] ?? [],
            appPaths: [],
            fontPaths: [],
            caveats: nonEmpty(json["caveats"]),
            tap: nonEmpty(json["tap"]),
            deprecation: notice(in: json, flag: "deprecated", prefix: "deprecation"),
            disabling: notice(in: json, flag: "disabled", prefix: "disable")
        )
    }

    private static func cask(_ json: [String: Any]) -> HomebrewPackage? {
        guard let token = json["token"] as? String else { return nil }
        let artifacts = json["artifacts"] as? [[String: Any]] ?? []
        return HomebrewPackage(
            token: token,
            fullToken: json["full_token"] as? String ?? token,
            isCask: true,
            names: json["name"] as? [String] ?? [],
            description: nonEmpty(json["desc"]),
            homepage: nonEmpty(json["homepage"]),
            version: json["version"] as? String,
            installedVersion: json["installed"] as? String,
            isInstalledAsDependency: false,
            isOutdated: json["outdated"] as? Bool ?? false,
            isPinned: json["pinned"] as? Bool ?? false,
            autoUpdates: json["auto_updates"] as? Bool ?? false,
            isKegOnly: false,
            license: nil,
            dependencies: [],
            conflicts: (json["conflicts_with"] as? [String: Any])?["cask"] as? [String] ?? [],
            appPaths: targets(of: "app", in: artifacts),
            fontPaths: targets(of: "font", in: artifacts),
            caveats: nonEmpty(json["caveats"]),
            tap: nonEmpty(json["tap"]),
            deprecation: notice(in: json, flag: "deprecated", prefix: "deprecation"),
            disabling: notice(in: json, flag: "disabled", prefix: "disable")
        )
    }

    /// Where a cask's artifacts of `kind` (`app`, `font`) install.
    private static func targets(of kind: String, in artifacts: [[String: Any]]) -> [String] {
        artifacts.compactMap { artifact in
            guard artifact[kind] != nil else { return nil }
            return artifact["target"] as? String
        }
    }

    private static func notice(in json: [String: Any], flag: String, prefix: String) -> Notice? {
        guard json[flag] as? Bool == true else { return nil }
        return Notice(
            reason: nonEmpty(json["\(prefix)_reason"]),
            replacement: nonEmpty(json["\(prefix)_replacement_formula"])
                ?? nonEmpty(json["\(prefix)_replacement_cask"])
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else { return nil }
        return string
    }
}
