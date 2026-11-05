import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search action

extension RecentFilesModule {
    func fixedActions() -> [RecentFilesAction] {
        [
            RecentFilesAction(
                id: ActionID(module: "recentFiles", name: "searchFiles"),
                title: "Search Recent Files",
                subtitle: "Open a file from Finder's Recents",
                iconName: "doc.badge.clock",
                relevanceScore: 0.85,
                keywords: ["recent", "recents", "files", "documents", "finder", "opened", "search"],
                parameters: [
                    ActionParameter(
                        id: "file",
                        label: "File",
                        type: .dynamicSelection(hint: "file"),
                        isRequired: true,
                        // Ranked here, by match and how recently each was used.
                        rankedByModule: true
                    ),
                ]
            ) { [self] values in
                // The only option without a path is the one saying Spotlight failed.
                guard let path = values["file"], !path.isEmpty else {
                    throw await sourceError ?? RecentFilesError.nothingChosen
                }
                try await open(path)
                return .dismiss
            },
        ]
    }
}

// MARK: - Rows

extension RecentFilesModule {
    static func actionID(for path: String) -> ActionID {
        ActionID(module: "recentFiles", name: filePrefix + StableID.hash(path))
    }

    func fileAction(_ match: RecentFilesIndex.Match) -> RecentFilesAction {
        let file = match.file
        return RecentFilesAction(
            id: Self.actionID(for: file.path),
            title: file.name,
            // The folder tells same-named files apart and holds the words the picker's
            // word-prefix gate checks besides the name. Not keywords: a keyword equal to
            // the query counts as much as the title, which would put every file in a
            // folder named like the query above actions named for it.
            subtitle: file.folder,
            iconName: Self.symbolName(for: file.type),
            appIconPath: defaultApp(for: file),
            // Recently used files ahead of comparable matches; below most actions.
            relevanceScore: 0.3 + 0.2 * match.recency,
            keywords: [],
            file: file,
            requiresWordPrefixMatch: true
        ) { [self] _ in
            try await open(file.path)
            return .dismiss
        }
    }

    /// A symbol for a type, where a list can't show its Finder icon.
    static func symbolName(for type: UTType) -> String {
        let symbols: [(UTType, String)] = [
            (.pdf, "doc.richtext"),
            (.image, "photo"),
            (.audiovisualContent, "film"),
            (.audio, "music.note"),
            (.archive, "doc.zipper"),
            (.diskImage, "externaldrive"),
            (.spreadsheet, "tablecells"),
            (.presentation, "rectangle.on.rectangle"),
            (.sourceCode, "chevron.left.forwardslash.chevron.right"),
            (.font, "textformat"),
            (.text, "doc.text"),
        ]
        return symbols.first { type.conforms(to: $0.0) }?.1 ?? "doc"
    }
}

// MARK: - Search options

extension RecentFilesModule {
    func provideParameterOptions(for parameterID: String, in actionID: ActionID, query: String) async
        -> [ParameterOption]
    {
        guard parameterID == "file", actionID.actionName == "searchFiles" else { return [] }
        await waitForFirstLoad()
        if index.isEmpty, let sourceError {
            return [Self.failureOption("Couldn't list recent files", sourceError)]
        }
        return index.search(query, mode: .anywhere, limit: Self.searchLimit).map { match in
            fileOption(match.file, query: query)
        }
    }

    func fileOption(_ file: RecentFile, query: String) -> ParameterOption {
        let appPath = defaultApp(for: file)
        var option = ParameterOption(
            id: file.path,
            label: file.name,
            subtitle: "\(file.folder) · \(RecentFilePreview.relative(file.lastUsed))",
            iconName: Self.symbolName(for: file.type),
            makePreview: { AnyView(RecentFilePreview(file: file, appPath: appPath)) }
        )
        let ranges = Self.highlights(of: query, in: file.name)
        option.labelHighlightRanges = ranges.isEmpty ? nil : ranges
        return option
    }

    /// Where each word of `query` first appears in `label`.
    static func highlights(of query: String, in label: String) -> [Range<String.Index>] {
        query.split(whereSeparator: \.isWhitespace).compactMap { word in
            label.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        }
    }

    static func failureOption(_ label: String, _ error: Error) -> ParameterOption {
        ParameterOption(
            id: "",
            label: label,
            subtitle: error.localizedDescription,
            iconName: "exclamationmark.triangle"
        )
    }
}
