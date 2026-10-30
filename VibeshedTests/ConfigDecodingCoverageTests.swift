@testable import Vibeshed
import XCTest
import Yams

/// Every config type, every module section. A section that fails to decode isn't an
/// error the user sees: `ModuleConfigDecoder` and `ConfigManager` log it and carry on
/// with the defaults, so these tests decode without that fallback.
@MainActor
final class ConfigDecodingCoverageTests: XCTestCase {
    /// A hand-written `init(from:)` reads every field: a value with each one changed comes
    /// back from an encode/decode round trip unchanged. A field the decoder skips would
    /// come back as its default.
    func testEveryFieldIsDecoded() throws {
        try assertRoundTrip(ApplicationConfig(showRunningOnly: true, excludedBundleIDs: ["a"], cacheTTLSeconds: 9))
        try assertRoundTrip(AudioConfig(volumeSteps: [10], volumeStep: 5, enabledActions: ["mute"]))
        try assertRoundTrip(BookmarkConfig(
            browsers: ["safari"], maxBookmarks: 1, maxVisited: 2, showMostVisited: false, minVisitCount: 4,
            cacheTTLSeconds: 5
        ))
        try assertRoundTrip(BrowserConfig(
            browsers: ["arc"], cacheTTLSeconds: 1, maxResults: 2, showCloseActions: false
        ))
        try assertRoundTrip(CalendarConfig(
            lookaheadHours: 1, lookbehindMinutes: 2, excludedCalendars: ["a"], includedCalendars: ["b"],
            showAllDayEvents: true, showDeclinedEvents: true, showOpenCalendarAction: false, enabledActions: ["x"]
        ))
        try assertRoundTrip(ClipboardConfig(
            maxItems: 1, pollingInterval: 2, excludePatterns: ["^x"], showClearAction: false, pasteOnSelect: false,
            enabledActions: ["x"]
        ))
        try assertRoundTrip(GitHubConfig(
            token: "t", defaultOwner: "o", repoOwners: ["r"], maxResults: 1, searchTypes: ["pr"],
            enabledActions: ["x"], showRepos: false, showNotifications: false, useGitHubCLI: false, ghPath: "/g",
            showPullRequests: false, pullRequestFilters: ["assignee"], maxPullRequests: 2, pullRequestRefresh: 60
        ))
        try assertRoundTrip(HomebrewConfig(brewPath: "/b", enabledActions: ["x"]))
        try assertRoundTrip(ITermConfig(
            maxResults: 1, showCWD: false, showJobName: false, enabledActions: ["x"], commands: ["a": "b"],
            defaultProfile: "p"
        ))
        try assertRoundTrip(JetBrainsConfig(
            maxResults: 1, enabledActions: ["x"], enabledIDEs: ["idea"], openInNewWindow: true
        ))
        try assertRoundTrip(MathConfig(
            decimalPlaces: 1, enableCurrency: false, currencyRateTTL: 2, copyOnSelect: false,
            showBaseConversions: false, enabledActions: ["x"]
        ))
        try assertRoundTrip(MeetingPrepConfig(
            prepWindowMinutes: 1, hideApps: ["a"], keepApps: ["b"], autoJoinVideo: true, enabledActions: ["x"]
        ))
        try assertRoundTrip(ProcessesConfig(cacheTTLSeconds: 1, maxResults: 2, excludedNames: ["a"]))
        try assertRoundTrip(SpotifyConfig(
            clientId: "c", maxSearchResults: 1, searchTypes: ["track"], enabledActions: ["x"], showNowPlaying: false
        ))
        try assertRoundTrip(SystemConfig(screenshotPath: "/s", enabledActions: ["x"]))
        try assertRoundTrip(TelegramConfig(
            chats: [TelegramChatEntry(name: "n")], showLaunchAction: false, showSavedMessages: false,
            enabledActions: ["x"]
        ))
        try assertRoundTrip(TimerConfig(
            defaultSound: "Ping", presetDurations: [2], maxActiveTimers: 1, enabledActions: ["x"]
        ))
        try assertRoundTrip(VSCodeConfig(
            maxResults: 1, showFiles: true, showRemote: true, enabledActions: ["x"], codePath: "/c",
            variants: ["a": "b"]
        ))
        try assertRoundTrip(ZedConfig(maxResults: 1, showRemote: true, enabledActions: ["x"], zedPath: "/z"))
        try assertRoundTrip(ZoomConfig(
            meetings: [ZoomMeetingEntry(name: "n")], personalMeetingId: "1", showStartMeeting: false,
            showJoinAction: false, showLaunchAction: false, enabledActions: ["x"]
        ))
        try assertRoundTrip(SelfConfig(enabledActions: ["x"]))
        try assertRoundTrip(SettingsConfig(enabledPanes: ["wifi"], customPanes: ["a": "b"]))
    }

    func testEveryFieldIsDecodedInWallpaper() throws {
        try assertRoundTrip(WallpaperConfig(
            sources: ["met"], maxResultsPerSource: 3, orientation: "any", scaling: "fit", downloadDirectory: "/w",
            wallhavenAPIKey: "k", wallhavenCategories: ["people"], unsplashAccessKey: "u", enabledActions: ["x"]
        ))
    }

    /// The AI vendor configs, which all have their own decoders.
    func testEveryFieldIsDecodedInAIConfigs() throws {
        try assertRoundTrip(changed(AnthropicConfig()) {
            $0.maxResults = 1
            $0.sources = ["claudeCode"]
            $0.enabledActions = ["x"]
            $0.showLaunchers = false
            $0.resumeIn = .desktop
            $0.showAlternateResume = true
            $0.claudePath = "/c"
            $0.terminalApp = "terminal"
        })
        try assertRoundTrip(changed(OpenAIConfig()) {
            $0.maxResults = 1
            $0.sources = ["x"]
            $0.enabledActions = ["x"]
            $0.showLaunchers = false
            $0.newSessionInTerminal = true
            $0.codexPath = "/c"
            $0.terminalApp = "terminal"
        })
        try assertRoundTrip(changed(OpenCodeConfig()) {
            $0.maxResults = 1
            $0.sources = ["x"]
            $0.enabledActions = ["x"]
            $0.showLaunchers = false
            $0.opencodePath = "/c"
            $0.terminalApp = "terminal"
        })
    }

    /// The configs that already had their own decoders.
    func testEveryFieldIsDecodedByEarlierDecoders() throws {
        try assertRoundTrip(changed(EmojiConfig()) { $0.pasteOnSelect = true })
        try assertRoundTrip(changed(GhosttyConfig()) {
            $0.maxResults = 1
            $0.showCWD = false
            $0.commands = ["a": "b"]
            $0.enabledActions = ["x"]
        })
        try assertRoundTrip(changed(TerminalConfig()) {
            $0.commands = ["a": "b"]
            $0.enabledActions = ["x"]
        })
        try assertRoundTrip(changed(NotesConfig()) {
            $0.maxResults = 1
            $0.searchContent = false
            $0.newNoteFolder = "f"
            $0.enabledActions = ["x"]
        })
        try assertRoundTrip(changed(MenuConfig()) {
            $0.showInSearch = false
            $0.maxSubmenuItems = 1
            $0.cacheTTLSeconds = 1
            $0.excludedBundleIDs = ["a"]
        })
        try assertRoundTrip(changed(PerformanceConfig()) {
            $0.sampleInterval = 1
            $0.historyMinutes = 1
            $0.networkInterfaces = ["en0"]
            $0.enabledActions = ["x"]
        })
        try assertRoundTrip(changed(WebSearchConfig()) {
            $0.engines = [WebSearchConfig.Engine(name: "n", urlTemplate: "u", iconName: "i")]
            $0.minQueryLength = 1
        })
        try assertRoundTrip(changedThemeConfig())
    }

    func testEveryFieldIsDecodedInWindowAndTiling() throws {
        try assertRoundTrip(WindowConfig(
            horizontalStops: [SizeStop(value: 1, unit: .pixels)],
            verticalStops: [SizeStop(value: 2, unit: .pixels)],
            displays: [DisplayStopsConfig(match: "main")],
            padding: PaddingConfig(gap: 1),
            includeMinimized: false,
            enlargeShrinkStep: SizeStop(value: 5, unit: .pixels),
            focusBorder: FocusBorderConfig()
        ))
        try assertRoundTrip(FocusBorderConfig(width: 1, cornerRadius: 1, minimumSize: 1, pollingInterval: 1))
        try assertRoundTrip(PaddingConfig(top: 1, bottom: 2, left: 3, right: 4, gap: 5))
        try assertRoundTrip(TilingConfig(
            displays: [DisplayGridConfig(match: "main", columns: [1], rows: [1], padding: nil)],
            defaultGrid: DisplayGridConfig(match: nil, columns: [2], rows: [1], padding: nil),
            padding: PaddingConfig(gap: 1),
            enabledActions: ["x"],
            autoTile: AutoTileConfig(pollingInterval: 2)
        ))
        try assertRoundTrip(AutoTileConfig(
            excludedBundleIDs: ["a"], pollingInterval: 2, minimumSize: 1, maximizeSingleWindow: false
        ))
    }

    func testEveryFieldIsDecodedInTopLevelSections() throws {
        try assertRoundTrip(AppConfig.AppearanceConfig(
            panelWidth: 1, panelHeight: 2, cornerRadius: 3, rowHeight: 4, searchBarHeight: 5, fill: 0.5,
            overlay: AppConfig.OverlayConfig()
        ))
        try assertRoundTrip(AppConfig.LayoutCorrectionConfig(enabled: false))
        try assertRoundTrip(AppConfig.PickerConfig(resetAfter: 3))
        try assertRoundTrip(URLRoutingConfig(
            rules: [URLRoutingRule(pattern: "p", browser: "b", profile: nil, action: nil)],
            defaultBrowser: "b",
            defaultProfile: "p",
            registerAsDefaultBrowser: false
        ))
    }

    /// An empty mapping is the module's `defaultConfig` — the decoders' fallbacks match
    /// the property defaults. Not tiling: only a section with no value at all gets
    /// `defaultValue`'s grid (see `PartialConfigDecodingTests`).
    func testEmptySectionIsTheDefaultConfig() throws {
        for (moduleID, section) in Self.moduleSections where moduleID != "tiling" {
            XCTAssertTrue(try section.emptyIsDefault(), moduleID)
        }
    }

    // MARK: - Real config files

    func testExampleConfigDecodes() throws {
        let yaml = try String(contentsOf: Self.exampleConfigURL, encoding: .utf8)
        let root = try XCTUnwrap(Yams.compose(yaml: yaml)?.mapping)
        _ = try decodeSection(AppConfig.AppearanceConfig.self, "appearance", in: root)
        _ = try decodeSection(AppConfig.PickerConfig.self, "picker", in: root)
        _ = try decodeSection([KeyBindingEntry].self, "keybindings", in: root)
        _ = try decodeSection([String].self, "keybindingExclusions", in: root)
        _ = try decodeSection([AliasEntry].self, "aliases", in: root)
        _ = try decodeSection(AppConfig.LayoutCorrectionConfig.self, "layoutCorrection", in: root)
        _ = try decodeSection(URLRoutingConfig.self, "urlRouting", in: root)
        try assertModuleSectionsDecode(in: yaml)
    }

    /// The config written on first launch, with every integration's software found.
    func testGeneratedConfigDecodes() throws {
        let everything = SoftwareEnvironment(
            isAppInstalled: { _ in true },
            fileExists: { _ in true },
            homeDirectory: "/Users/test"
        )
        try assertModuleSectionsDecode(in: DefaultConfig.yaml(detected: SoftwareIntegration.detect(in: everything)))
    }
}

// MARK: - Helpers

private extension ConfigDecodingCoverageTests {
    struct ModuleSection {
        /// Decodes a section strictly, without the fallback to defaults, and validates it.
        let validate: (Data) throws -> ConfigValidationResult
        let emptyIsDefault: () throws -> Bool

        init<M: ModuleConfigurable>(_: M.Type) {
            validate = { M.validate(try YAMLDecoder().decode(M.Config.self, from: $0)) }
            emptyIsDefault = { try YAMLDecoder().decode(M.Config.self, from: "{}") == M.defaultConfig }
        }
    }

    static var moduleSections: [String: ModuleSection] {
        [
            "application": ModuleSection(ApplicationModule.self),
            "menu": ModuleSection(MenuModule.self),
            "system": ModuleSection(SystemModule.self),
            "processes": ModuleSection(ProcessesModule.self),
            "performance": ModuleSection(PerformanceModule.self),
            "settings": ModuleSection(SettingsModule.self),
            "theme": ModuleSection(ThemeModule.self),
            "wallpaper": ModuleSection(WallpaperModule.self),
            "self": ModuleSection(SelfModule.self),
            "audio": ModuleSection(AudioModule.self),
            "clipboard": ModuleSection(ClipboardModule.self),
            "browser": ModuleSection(BrowserModule.self),
            "spotify": ModuleSection(SpotifyModule.self),
            "github": ModuleSection(GitHubModule.self),
            "vscode": ModuleSection(RecentProjectsModule<VSCodeProvider>.self),
            "jetbrains": ModuleSection(RecentProjectsModule<JetBrainsProvider>.self),
            "zed": ModuleSection(RecentProjectsModule<ZedProvider>.self),
            "iterm": ModuleSection(ITermModule.self),
            "ghostty": ModuleSection(GhosttyModule.self),
            "terminal": ModuleSection(TerminalModule.self),
            "anthropic": ModuleSection(AISessionsModule<AnthropicProvider>.self),
            "openai": ModuleSection(AISessionsModule<OpenAIProvider>.self),
            "opencode": ModuleSection(AISessionsModule<OpenCodeProvider>.self),
            "telegram": ModuleSection(TelegramModule.self),
            "zoom": ModuleSection(ZoomModule.self),
            "calendar": ModuleSection(CalendarModule.self),
            "meetingPrep": ModuleSection(MeetingPrepModule.self),
            "bookmark": ModuleSection(BookmarkModule.self),
            "notes": ModuleSection(NotesModule.self),
            "timer": ModuleSection(TimerModule.self),
            "math": ModuleSection(MathModule.self),
            "homebrew": ModuleSection(HomebrewModule.self),
            "websearch": ModuleSection(WebSearchModule.self),
            "emoji": ModuleSection(EmojiModule.self),
            "window": ModuleSection(WindowModule.self),
            "tiling": ModuleSection(TilingModule.self),
        ]
    }

    static let exampleConfigURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("config.example.yaml")

    /// Every module section in `yaml` that has keys decodes and validates. One with no
    /// value runs on `defaultConfig` without decoding anything.
    func assertModuleSectionsDecode(in yaml: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let config = try ConfigManager.parseYAML(yaml)
        let sections = Self.moduleSections
        XCTAssertEqual(
            Set(config.moduleConfigs.keys).subtracting(sections.keys), [],
            "add these modules to moduleSections", file: file, line: line
        )
        for (moduleID, data) in config.moduleConfigs {
            let text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let section = sections[moduleID], let text, !["", "null", "~"].contains(text) else { continue }
            do {
                let result = try section.validate(data)
                XCTAssertTrue(result.isValid, "\(moduleID): \(result.errors)", file: file, line: line)
            } catch {
                XCTFail("\(moduleID): \(error)", file: file, line: line)
            }
        }
    }

    func decodeSection<T: Decodable>(_: T.Type, _ key: String, in root: Node.Mapping) throws -> T {
        let node = try XCTUnwrap(root[Node(key)], "no '\(key)' section")
        return try YAMLDecoder().decode(T.self, from: Yams.serialize(node: node))
    }

    /// Checks that `value` sets every field to something other than its default, then
    /// that it survives encoding and decoding.
    func assertRoundTrip<C: Codable & Equatable>(
        _ value: C,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let defaults = try YAMLDecoder().decode(C.self, from: "{}")
        let unchanged = zip(Mirror(reflecting: value).children, Mirror(reflecting: defaults).children)
            .filter { String(describing: $0.0.value) == String(describing: $0.1.value) }
            .compactMap { $0.0.label }
        XCTAssertEqual(unchanged, [], "\(C.self): give these a non-default value", file: file, line: line)
        let yaml = try YAMLEncoder().encode(value)
        XCTAssertEqual(try YAMLDecoder().decode(C.self, from: yaml), value, "\(C.self)", file: file, line: line)
    }

    func changed<C>(_ value: C, _ change: (inout C) -> Void) -> C {
        var value = value
        change(&value)
        return value
    }

    func changedThemeConfig() throws -> ThemeConfig {
        var config = ThemeConfig()
        config.themes = [ThemeDefinition(name: "t", pair: "p", keywords: ["k"])]
        config.includeBuiltInThemes = false
        config.themesDirectory = "/t"
        config.targets = ["wallpaper"]
        config.livePreview = false
        config.generateWallpapers = false
        config.wallpaperStyle = "mesh"
        config.wallpaperGrain = false
        config.itermDefaultProfile = false
        config.terminalDefaultProfile = false
        config.folders = ["/f"]
        config.templates = try YAMLDecoder().decode([ThemeTemplateConfig].self, from: "[{ source: s, target: t }]")
        config.hooks = ["h"]
        config.fonts = ["f"]
        config.vscodeVariants = ["a": "b"]
        config.jetbrainsIDEs = ["idea"]
        config.enabledActions = ["x"]
        return config
    }
}
