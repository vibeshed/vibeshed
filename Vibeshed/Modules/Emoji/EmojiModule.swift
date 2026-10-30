import Foundation
import OSLog

actor EmojiModule: ModuleConfigurable {
    let id = "emoji"
    let displayName = "Emoji"
    let iconName = "face.smiling"
    var isEnabled = true

    typealias Config = EmojiConfig
    static var defaultConfig: Config? {
        .init()
    }

    private var config: EmojiConfig = .init()
    private let log = Log.module("emoji")

    func initialize(context: ModuleContext) async throws {
        log.info("Emoji module initialized (\(EmojiCatalog.entries.count, privacy: .public) emoji)")
    }

    func configDidUpdate(_ config: EmojiConfig) async {
        self.config = config
        log.debug("Config updated")
    }

    /// Individual emoji are only offered as options of `emoji/find`, not as
    /// top-level results, so they don't crowd out everything else in search.
    func provideActions(query: String, scoring: ScoringContext) async -> [any Action] {
        [buildFindAction()]
    }

    /// The whole catalog; the picker ranks it against the query like actions,
    /// matching CLDR keywords too (e.g. "car" → 🚗 Automobile).
    func provideParameterOptions(
        for parameterID: String,
        in actionID: ActionID,
        query: String
    ) async -> [ParameterOption] {
        parameterID == "emoji" ? Self.options : []
    }

    /// Built once: catalog order (emoji-test.txt) groups related emoji sensibly,
    /// which is also the empty-query order.
    static let options: [ParameterOption] = EmojiCatalog.entries.map { entry in
        ParameterOption(
            id: entry.char,
            label: "\(entry.char)  \(entry.name.capitalized)",
            keywords: entry.keywords
        )
    }

    /// Emoji IDs are cheaply reversible ("emoji/copy.<slug>" → catalog entry), so
    /// resolve directly instead of the default `provideActions` scan (which only
    /// holds `emoji/find`). This keeps single-emoji actions usable from
    /// keybindings, aliases, and vibeshed:// URIs.
    func action(id: ActionID) async -> (any Action)? {
        guard id.moduleID == self.id else { return nil }
        if id.actionName == "find" { return buildFindAction() }
        guard id.actionName.hasPrefix("copy.") else { return nil }
        let slug = String(id.actionName.dropFirst("copy.".count))
        guard let entry = EmojiCatalog.entries.first(where: {
            $0.name.replacingOccurrences(of: " ", with: "-") == slug
        }) else { return nil }
        return buildCopyAction(for: entry)
    }

    // MARK: - Action Building

    private func buildFindAction() -> EmojiAction {
        let pasteOnSelect = config.pasteOnSelect
        return EmojiAction(
            id: ActionID(module: "emoji", name: "find"),
            title: "Find Emoji",
            subtitle: pasteOnSelect ? "Search and paste an emoji" : "Search and copy an emoji",
            iconName: "face.smiling",
            relevanceScore: 0.7,
            keywords: ["emoji", "emoticon", "smiley", "find", "search", "insert", "symbol"],
            parameters: [
                ActionParameter(
                    id: "emoji",
                    label: "Emoji",
                    type: .dynamicSelection(hint: "emoji"),
                    isRequired: true
                ),
            ],
            typesIntoFrontmostApp: pasteOnSelect
        ) { values in
            guard let char = values["emoji"], !char.isEmpty else {
                return .showResult(title: "Error", body: "No emoji selected")
            }
            await Self.deliver(char, pasteOnSelect: pasteOnSelect)
            return .dismiss
        }
    }

    private func buildCopyAction(for entry: EmojiEntry) -> EmojiAction {
        let char = entry.char
        let pasteOnSelect = config.pasteOnSelect
        let slug = entry.name.replacingOccurrences(of: " ", with: "-")
        return EmojiAction(
            id: ActionID(module: "emoji", name: "copy.\(slug)"),
            title: "\(char)  \(entry.name.capitalized)",
            subtitle: pasteOnSelect ? "Paste emoji" : "Copy emoji to clipboard",
            iconName: "face.smiling",
            keywords: ["emoji", entry.name] + entry.keywords,
            typesIntoFrontmostApp: pasteOnSelect
        ) { _ in
            await Self.deliver(char, pasteOnSelect: pasteOnSelect)
            return .dismiss
        }
    }

    private static func deliver(_ char: String, pasteOnSelect: Bool) async {
        await ClipboardManager.writeToPasteboard(char)
        if pasteOnSelect {
            await ClipboardManager.pasteFromPasteboard()
        }
    }
}
