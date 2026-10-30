import Foundation

/// Terminal tools with their own truecolor themes, which the terminal palette (iTerm
/// target) can't reach. Each gets an exact-palette theme file under a fixed name, so
/// the tool's config only has to point at it once; changes show on the tool's next run.
/// (fzf needs no target: configured with ANSI slots, it follows the iTerm palette live.)
enum CLITools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        + ["~/.cargo/bin", "~/.local/bin"].map(ThemeFiles.expand)

    static func executable(_ name: String) -> String? {
        searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var configHome: String {
        ThemeFiles.home.appendingPathComponent(".config").path
    }
}

// MARK: - bat

/// bat: writes `<config dir>/themes/Vibeshed.tmTheme` and rebuilds bat's theme cache.
/// Select it once with `--theme=Vibeshed` in bat's config.
struct BatTarget: ThemeTarget {
    let id = ThemeTargetID.bat
    let displayName = "bat"

    static let themeName = "Vibeshed"

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        guard let bat = CLITools.executable("bat") else { return .skipped("not installed") }
        let configDir = await ShellCommand.run("'\(bat)' --config-dir").output
        guard !configDir.isEmpty else { return .failed("couldn't locate bat's config folder") }
        do {
            let theme = try CLIThemeBuilder.tmTheme(request.palette, name: Self.themeName)
            try ThemeFiles.write(theme, to: "\(configDir)/themes/\(Self.themeName).tmTheme")
        } catch {
            return .failed(error.localizedDescription)
        }
        let build = await ShellCommand.run("'\(bat)' cache --build", timeout: 60)
        guard build.status == 0 else { return .failed("bat cache --build: \(build.output)") }

        let config = ThemeFiles.read("\(configDir)/config") ?? ""
        return config.contains("=\(Self.themeName)")
            ? .applied()
            : .applied(note: "add --theme=\(Self.themeName) to \(configDir)/config")
    }
}

// MARK: - lsd

/// lsd: rewrites `~/.config/lsd/colors.yaml` (used when `color.theme: custom`).
struct LsdTarget: ThemeTarget {
    let id = ThemeTargetID.lsd
    let displayName = "lsd"

    private static var configDir: String { "\(CLITools.configHome)/lsd" }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        guard CLITools.executable("lsd") != nil || ThemeFiles.exists(Self.configDir) else {
            return .skipped("not installed")
        }
        do {
            let colors = CLIThemeBuilder.lsdColors(request.palette, themeName: request.theme.name)
            try ThemeFiles.write(colors, to: "\(Self.configDir)/colors.yaml")
        } catch {
            return .failed(error.localizedDescription)
        }
        let config = ThemeFiles.read("\(Self.configDir)/config.yaml") ?? ""
        let usesCustom = config.range(of: #"theme:\s*custom"#, options: .regularExpression) != nil
        return usesCustom ? .applied() : .applied(note: "set color.theme: custom in lsd's config.yaml")
    }
}

// MARK: - micro

/// micro: writes `~/.config/micro/colorschemes/vibeshed.micro` and selects it in
/// micro's `settings.json`. Running editors keep their scheme until reopened.
struct MicroTarget: ThemeTarget {
    let id = ThemeTargetID.micro
    let displayName = "micro"

    static let schemeName = "vibeshed"

    private static var configDir: String { "\(CLITools.configHome)/micro" }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        guard CLITools.executable("micro") != nil || ThemeFiles.exists(Self.configDir) else {
            return .skipped("not installed")
        }
        do {
            let scheme = CLIThemeBuilder.microScheme(request.palette, themeName: request.theme.name)
            try ThemeFiles.write(scheme, to: "\(Self.configDir)/colorschemes/\(Self.schemeName).micro")
            let settingsPath = "\(Self.configDir)/settings.json"
            var settings = JSONCDocument(text: ThemeFiles.read(settingsPath))
            try settings.setValue(Self.schemeName, forKey: "colorscheme")
            try ThemeFiles.write(settings.text, to: settingsPath)
            return .applied()
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - btop

/// btop: writes `~/.config/btop/themes/vibeshed.theme`, selects it in `btop.conf`, and
/// sends running btops SIGUSR2 — btop's hot-reload signal — so they retint live.
struct BtopTarget: ThemeTarget {
    let id = ThemeTargetID.btop
    let displayName = "btop"
    var supportsPreview: Bool { true }

    static let themeName = "vibeshed"

    private static var configDir: String { "\(CLITools.configHome)/btop" }
    private static var configPath: String { "\(configDir)/btop.conf" }
    private static var themePath: String { "\(configDir)/themes/\(themeName).theme" }

    func apply(_ request: ThemeApplyRequest) async -> ThemeTargetOutcome {
        guard CLITools.executable("btop") != nil || ThemeFiles.exists(Self.configDir) else {
            return .skipped("not installed")
        }
        do {
            let theme = CLIThemeBuilder.btopTheme(request.palette, themeName: request.theme.name)
            try ThemeFiles.write(theme, to: Self.themePath)
            try ThemeFiles.write(Self.selectingTheme(in: ThemeFiles.read(Self.configPath)), to: Self.configPath)
        } catch {
            return .failed(error.localizedDescription)
        }
        Self.reloadRunning()
        return .applied()
    }

    func snapshot(config _: ThemeConfig) async -> ThemeRestore? {
        let files = ThemeFiles.snapshot([Self.configPath, Self.themePath])
        return {
            await files()
            Self.reloadRunning()
        }
    }

    /// `btop.conf` with `color_theme` pointing at the Vibeshed theme; everything else kept.
    static func selectingTheme(in config: String?) -> String {
        let line = "color_theme = \"\(themeName)\""
        guard let config, !config.isEmpty else { return line + "\n" }
        var lines = config.components(separatedBy: "\n")
        let existing = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("color_theme") }
        if let index = existing {
            lines[index] = line
        } else {
            lines.insert(line, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func reloadRunning() {
        ProcessSignal.send(SIGUSR2, toProcessesNamed: "btop")
    }
}

// MARK: - Builders

enum CLIThemeBuilder {
    /// A TextMate theme (bat, and anything else that reads `.tmTheme`), token roles
    /// shared with the VS Code theme so both highlight code the same way.
    static func tmTheme(_ palette: ThemePalette, name: String) throws -> String {
        let global: [String: String] = [
            "background": palette.background.hex,
            "foreground": palette.foreground.hex,
            "caret": palette.cursor.hex,
            "lineHighlight": palette.lighterBackground.hex,
            "selection": palette.selectionBackground.hex,
            "gutter": palette.background.hex,
            "gutterForeground": palette.muted.hex,
            "invisibles": palette.background.mix(palette.foreground, 0.2).hex,
            "findHighlight": palette.accent.mix(palette.background, 0.5).hex,
        ]
        let rules: [[String: Any]] = VSCodeThemeBuilder.tokenColors(palette).compactMap { rule in
            guard let scopes = rule["scope"] as? [String], let settings = rule["settings"] else { return nil }
            return ["scope": scopes.joined(separator: ", "), "settings": settings]
        }
        let plist: [String: Any] = [
            "name": name,
            "settings": [["settings": global]] + rules,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    static func lsdColors(_ palette: ThemePalette, themeName: String) -> String {
        let muted = palette.muted.hex
        let border = palette.background.mix(palette.foreground, 0.25).hex
        func quoted(_ color: ThemeColor) -> String { "\"\(color.hex)\"" }
        return """
        # Generated by Vibeshed from the "\(themeName)" theme — rewritten on every theme switch.
        user: \(quoted(palette.foreground))
        group: "\(muted)"

        permission:
          read: \(quoted(palette.green))
          write: \(quoted(palette.yellow))
          exec: \(quoted(palette.red))
          exec-sticky: \(quoted(palette.magenta))
          no-access: "\(muted)"
          octal: \(quoted(palette.blue))
          acl: \(quoted(palette.blue))
          context: \(quoted(palette.cyan))

        attributes:
          archive: \(quoted(palette.orange))
          read: \(quoted(palette.green))
          hidden: "\(muted)"
          system: \(quoted(palette.magenta))

        date:
          hour-old: \(quoted(palette.green))
          day-old: \(quoted(palette.blue))
          older: "\(muted)"

        size:
          none: "\(muted)"
          small: \(quoted(palette.cyan))
          medium: \(quoted(palette.magenta))
          large: \(quoted(palette.red))

        inode:
          valid: \(quoted(palette.magenta))
          invalid: "\(muted)"

        links:
          valid: \(quoted(palette.accent))
          invalid: "\(muted)"

        tree-edge: "\(border)"

        git-status:
          default: "\(muted)"
          unmodified: "\(muted)"
          ignored: "\(muted)"
          new-in-index: \(quoted(palette.green))
          new-in-workdir: \(quoted(palette.green))
          typechange: \(quoted(palette.yellow))
          deleted: \(quoted(palette.red))
          renamed: \(quoted(palette.blue))
          modified: \(quoted(palette.orange))
          conflicted: \(quoted(palette.red))

        """
    }

    /// btop theme; roles follow Omarchy's `btop.theme.tpl`.
    static func btopTheme(_ palette: ThemePalette, themeName: String) -> String {
        let hex = { (key: String) in palette[key]?.hex ?? palette.foreground.hex }
        let roles: [(String, String)] = [
            ("main_bg", "background"), ("main_fg", "foreground"), ("title", "foreground"), ("hi_fg", "accent"),
            ("selected_bg", "selection_background"), ("selected_fg", "accent"), ("inactive_fg", "muted"),
            ("graph_text", "light_foreground"), ("meter_bg", "selection_background"),
            ("proc_misc", "light_foreground"), ("cpu_box", "magenta"), ("mem_box", "green"), ("net_box", "red"),
            ("proc_box", "accent"), ("div_line", "muted"),
            ("temp_start", "green"), ("temp_mid", "yellow"), ("temp_end", "red"),
            ("cpu_start", "cyan"), ("cpu_mid", "blue"), ("cpu_end", "magenta"),
            ("free_start", "magenta"), ("free_mid", "blue"), ("free_end", "cyan"),
            ("cached_start", "blue"), ("cached_mid", "cyan"), ("cached_end", "magenta"),
            ("available_start", "yellow"), ("available_mid", "red"), ("available_end", "red"),
            ("used_start", "green"), ("used_mid", "cyan"), ("used_end", "blue"),
            ("download_start", "yellow"), ("download_mid", "red"), ("download_end", "red"),
            ("upload_start", "green"), ("upload_mid", "cyan"), ("upload_end", "blue"),
            ("process_start", "cyan"), ("process_mid", "blue"), ("process_end", "magenta"),
        ]
        let gradient = ["background", "lighter_background", "selection_background", "muted", "dark_foreground",
                        "foreground", "light_foreground", "bright_foreground"]
        let lines = roles.map { "theme[\($0.0)]=\"\(hex($0.1))\"" }
            + gradient.enumerated().map { "theme[gradient_color_\($0.offset)]=\"\(hex($0.element))\"" }
        return "# Generated by Vibeshed from the \"\(themeName)\" theme — rewritten on every theme switch.\n"
            + lines.joined(separator: "\n") + "\n"
    }

    static func microScheme(_ palette: ThemePalette, themeName: String) -> String {
        let hex = { (key: String) in palette[key]?.hex ?? palette.foreground.hex }
        let bg = palette.background.hex
        let fg = palette.foreground.hex
        let panel = palette.darkBackground.hex
        let raised = palette.lighterBackground.hex
        let border = palette.background.mix(palette.foreground, 0.2).hex
        let links: [(String, String)] = [
            ("default", "\(fg),\(bg)"), ("comment", "italic \(hex("muted"))"),
            ("identifier", hex("blue")), ("identifier.class", hex("yellow")), ("identifier.var", hex("cyan")),
            ("constant", hex("orange")), ("constant.bool", hex("orange")), ("constant.number", hex("orange")),
            ("constant.specialChar", hex("bright_cyan")), ("constant.string", hex("green")),
            ("constant.string.char", hex("green")), ("constant.string.url", "underline \(hex("blue"))"),
            ("symbol", hex("bright_blue")), ("symbol.brackets", fg), ("symbol.operator", hex("bright_blue")),
            ("symbol.tag", hex("red")), ("type", hex("yellow")), ("type.keyword", hex("bright_magenta")),
            ("statement", hex("bright_magenta")), ("preproc", hex("magenta")), ("special", hex("magenta")),
            ("underlined", "underline \(hex("accent"))"), ("error", "bold \(hex("red"))"),
            ("todo", "bold \(hex("yellow"))"), ("hlsearch", "\(bg),\(hex("yellow"))"),
            ("match-brace", "\(bg),\(hex("accent"))"),
            ("statusline", "\(fg),\(panel)"), ("statusline.inactive", "\(hex("muted")),\(panel)"),
            ("tabbar", "\(hex("muted")),\(panel)"), ("tabbar.active", "\(fg),\(bg)"),
            ("indent-char", border), ("line-number", "\(hex("muted")),\(bg)"),
            ("current-line-number", "\(fg),\(raised)"), ("cursor-line", raised), ("color-column", raised),
            ("selection", "\(hex("selection_foreground")),\(hex("selection_background"))"),
            ("diff-added", hex("green")), ("diff-modified", hex("yellow")), ("diff-deleted", hex("red")),
            ("gutter-error", hex("red")), ("gutter-warning", hex("yellow")),
            ("divider", "\(border),\(bg)"), ("scrollbar", hex("muted")),
            ("message", fg), ("error-message", "bold \(hex("red"))"),
        ]
        let lines = links.map { "color-link \($0.0) \"\($0.1)\"" }.joined(separator: "\n")
        return "# Generated by Vibeshed from the \"\(themeName)\" theme — rewritten on every theme switch.\n"
            + lines + "\n"
    }
}
