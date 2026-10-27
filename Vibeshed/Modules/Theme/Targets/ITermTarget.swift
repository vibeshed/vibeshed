import Foundation

/// iTerm2: recolors every open session live over AppleScript, and keeps a "Vibeshed"
/// Dynamic Profile in sync (iTerm reloads those on change). That profile inherits
/// everything but colors from the user's own default profile and — unless
/// `itermDefaultProfile: false` — becomes iTerm's default, so new windows and iTerm
/// restarts keep the theme (see `ITermProfiles`).
/// `apps: { iterm: "<preset>" }` applies a built-in/imported color preset instead.
struct ITermTarget: ThemeTarget {
    let id = ThemeTargetID.iterm
    let displayName = "iTerm"
    var supportsPreview: Bool { true }

    static let bundleID = "com.googlecode.iterm2"
    static let profileGUID = "vibeshed-theme-profile"

    /// AppleScript session property → palette color, and the matching Dynamic Profile key.
    private static func colors(_ palette: ThemePalette) -> [(property: String, profileKey: String, color: ThemeColor)] {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var list: [(String, String, ThemeColor)] = [
            ("background color", "Background Color", palette.background),
            ("foreground color", "Foreground Color", palette.foreground),
            ("bold color", "Bold Color", palette.brightForeground),
            ("cursor color", "Cursor Color", palette.cursor),
            ("cursor text color", "Cursor Text Color", palette.background),
            ("selection color", "Selection Color", palette.selectionBackground),
            ("selected text color", "Selected Text Color", palette.selectionForeground),
        ]
        for (index, color) in palette.ansi.enumerated() {
            let name = (index >= 8 ? "bright " : "") + names[index % 8]
            list.append(("ANSI \(name) color", "Ansi \(index) Color", color))
        }
        return list
    }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        guard ThemeApps.isInstalled(Self.bundleID) else { return .skipped("not installed") }

        if let preset = request.override(.iterm) {
            guard ThemeApps.isRunning(Self.bundleID) else { return .skipped("not running") }
            return await Self.run(Self.presetScript(preset))
        }

        if !request.isPreview {
            do {
                // Resolve the parent before the default moves to the Vibeshed profile.
                let parent = ITermProfiles.parentProfileName()
                let font = CommittedFont.current.flatMap { font in
                    ITermFontTarget.normalFont(font.terminalFamily, like: ITermProfiles.parentNormalFont())
                }
                let profile = Self.profile(request.palette, parent: parent, normalFont: font)
                try ThemeFiles.writeJSON(["Profiles": [profile]], to: Self.profilePath)
            } catch {
                return .failed("dynamic profile: \(error.localizedDescription)")
            }
            ITermProfiles.setVibeshedDefault(request.config.itermDefaultProfile)
        }
        guard ThemeApps.isRunning(Self.bundleID) else { return .applied() }
        return await Self.run(Self.applyScript(request.palette))
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        guard ThemeApps.isRunning(Self.bundleID),
              let output = try? await AppleScriptRunner.run(Self.snapshotScript),
              let restore = Self.restoreScript(snapshot: output)
        else { return nil }
        return { _ = try? await AppleScriptRunner.run(restore) }
    }

    // MARK: - Scripts

    // Each Apple event iTerm answers costs ~17–20 ms, however small, so the scripts address
    // every session at once — an event per property, not per property per session (that
    // took 4–10 s per preview) — and the sets don't wait for replies: iTerm works through
    // queued events together, so 23 sets land in ~0.1 s instead of ~0.5 s.

    private static let allSessions = "every session of every tab of every window"

    private static var properties: [String] {
        colors(ThemePalette.placeholder).map(\.property)
    }

    static func applyScript(_ palette: ThemePalette) -> String {
        tell(colors(palette).map { "set \($0.property) of \(allSessions) to \($0.color.appleScriptList)" })
    }

    private static func presetScript(_ preset: String) -> String {
        tell(["set color preset of \(allSessions) to \"\(preset.escapedForAppleScript)\""])
    }

    /// One line per session: `id|r, g, b|r, g, b|…`, in `properties` order. The reads
    /// come back nested by window and tab.
    static var snapshotScript: String {
        let reads = properties.map { "\($0) of \(allSessions)" }.joined(separator: ", ")
        return """
        set AppleScript's text item delimiters to ", "
        tell application id "\(bundleID)"
            set ids to id of \(allSessions)
            set values to {\(reads)}
        end tell
        set out to ""
        repeat with w from 1 to count ids
            repeat with t from 1 to count item w of ids
                repeat with s from 1 to count item t of item w of ids
                    set out to out & item s of item t of item w of ids
                    repeat with v in values
                        set out to out & "|" & (item s of item t of item w of v as string)
                    end repeat
                    set out to out & linefeed
                end repeat
            end repeat
        end repeat
        return out
        """
    }

    /// Puts back what `snapshotScript` read: one event per distinct value of each property
    /// (just one when every session shared it), aimed at the sessions that had it by id.
    /// Sessions closed since are skipped; ones opened since are left alone.
    static func restoreScript(snapshot output: String) -> String? {
        let properties = properties
        var sessions: [(id: String, values: [String])] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == properties.count + 1 else { continue }
            sessions.append((fields[0], Array(fields.dropFirst())))
        }
        guard !sessions.isEmpty else { return nil }

        var sets: [String] = []
        for (index, property) in properties.enumerated() {
            var values: [String] = []
            var ids: [String: [String]] = [:]
            for session in sessions {
                let value = session.values[index]
                if ids[value] == nil { values.append(value) }
                ids[value, default: []].append(session.id)
            }
            for value in values {
                let filter = (ids[value] ?? []).map { "id is \"\($0.escapedForAppleScript)\"" }
                    .joined(separator: " or ")
                sets.append("set \(property) of (\(allSessions) whose \(filter)) to {\(value)}")
            }
        }
        return tell(sets)
    }

    /// Sends `statements` without waiting for each reply, then one query that iTerm answers
    /// only once it has handled them, so the script ends when the colors have landed. (A
    /// set iTerm rejects goes unreported; sending fails as before, e.g. without permission.)
    private static func tell(_ statements: [String]) -> String {
        """
        tell application id "\(bundleID)"
        ignoring application responses
        \(statements.joined(separator: "\n"))
        end ignoring
        count windows
        end tell
        """
    }

    private static func run(_ script: String) async -> ThemeTargetOutcome {
        do {
            try await AppleScriptRunner.run(script, timeout: 10)
            return .applied()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Dynamic Profile

    static var profilePath: String {
        ThemeFiles.home
            .appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles/vibeshed-theme.json").path
    }

    /// The Dynamic Profile: palette colors (and the font `theme/switchFont` applied) on top
    /// of the parent profile. Separate light/dark colors are switched off explicitly — a
    /// parent with them on would otherwise make iTerm read its own "(Dark)"/"(Light)" keys
    /// and ignore these.
    static func profile(_ palette: ThemePalette, parent: String?, normalFont: String? = nil) -> [String: Any] {
        var profile = baseProfile(parent: parent)
        profile["Use Separate Colors for Light and Dark Mode"] = false
        if let normalFont { profile["Normal Font"] = normalFont }
        for entry in colors(palette) {
            profile[entry.profileKey] = [
                "Red Component": entry.color.red,
                "Green Component": entry.color.green,
                "Blue Component": entry.color.blue,
                "Alpha Component": 1,
                "Color Space": "sRGB",
            ]
        }
        return profile
    }

    /// The Vibeshed profile with nothing of its own: everything comes from `parent`.
    static func baseProfile(parent: String?) -> [String: Any] {
        var profile: [String: Any] = ["Name": "Vibeshed", "Guid": profileGUID]
        if let parent { profile["Dynamic Profile Parent Name"] = parent }
        return profile
    }

    /// The Vibeshed profile as last written, when its file can be read.
    static func storedProfile() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: profilePath),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = file["Profiles"] as? [[String: Any]]
        else { return nil }
        return profiles.first { $0["Guid"] as? String == profileGUID }
    }
}

private extension ThemePalette {
    /// Only used for the property list, where the colors are irrelevant.
    static let placeholder: ThemePalette = (try? ThemePalette.resolve(
        ["background": "#000000", "foreground": "#ffffff", "red": "#ff0000", "green": "#00ff00",
         "yellow": "#ffff00", "blue": "#0000ff", "magenta": "#ff00ff", "cyan": "#00ffff"]
    )) ?? ThemePalette(mode: .dark, colors: [:])
}
